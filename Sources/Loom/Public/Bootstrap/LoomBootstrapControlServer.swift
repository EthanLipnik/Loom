//
//  LoomBootstrapControlServer.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Network

/// Authenticated remote peer presented to bootstrap control handlers.
public struct LoomBootstrapControlPeer: Sendable, Equatable {
    public let keyID: String
    public let publicKey: Data
    public let endpoint: String

    public init(keyID: String, publicKey: Data, endpoint: String) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.endpoint = endpoint
    }
}

/// Server-side runtime for the authenticated bootstrap control protocol.
@available(*, deprecated, message: "Bootstrap control is weaker than SSH host-certificate bootstrap. Prefer LoomSSHBootstrapClient with LoomSSHServerTrustConfiguration.")
public actor LoomBootstrapControlServer {
    public typealias StatusHandler = @Sendable (LoomBootstrapControlPeer) async throws -> LoomBootstrapControlResult
    public typealias UnlockHandler =
        @Sendable (LoomBootstrapControlPeer, LoomBootstrapCredentials) async throws -> LoomBootstrapControlResult

    private let controlAuthSecret: String
    private let statusHandler: StatusHandler
    private let unlockHandler: UnlockHandler
    private let replayProtector = LoomReplayProtector()
    private var listener: NWListener?

    public init(
        controlAuthSecret: String,
        onStatus: @escaping StatusHandler,
        onUnlock: @escaping UnlockHandler
    ) {
        self.controlAuthSecret = controlAuthSecret
        statusHandler = onStatus
        unlockHandler = onUnlock
    }

    public func start(port: UInt16 = Loom.defaultControlPort) async throws -> UInt16 {
        let actualPort = NWEndpoint.Port(rawValue: port) ?? .any
        listener = try NWListener(using: .tcp, on: actualPort)
        guard let listener else {
            throw LoomError.protocolError("Failed to create bootstrap control server.")
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuationBox.resume(returning: port)
                    }
                case let .failed(error):
                    continuationBox.resume(throwing: error)
                case .cancelled:
                    continuationBox.resume(throwing: LoomError.protocolError("Bootstrap control server cancelled."))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        defer { connection.cancel() }

        var requestID: UUID?

        do {
            try await awaitReady(connection)
            let requestData = try await receiveLine(
                over: connection,
                maxBytes: LoomMessageLimits.maxBootstrapControlLineBytes
            )
            requestID = Self.extractRequestID(from: requestData)
            let request = try JSONDecoder().decode(LoomBootstrapControlRequest.self, from: requestData)
            requestID = request.requestID
            let peer = try await validate(request, endpoint: connection.endpoint.debugDescription)
            let responseResult = try await process(request, peer: peer)
            let response = LoomBootstrapControlResponse(
                requestID: request.requestID,
                success: responseResult.success,
                availability: responseResult.state,
                message: responseResult.message,
                canRetry: responseResult.canRetry,
                retriesRemaining: responseResult.retriesRemaining,
                retryAfterSeconds: responseResult.retryAfterSeconds
            )
            try await sendLine(response, over: connection)
        } catch let error as LoomBootstrapControlError {
            try? await sendLine(Self.makeErrorResponse(requestID: requestID, message: error.errorDescription), over: connection)
        } catch {
            try? await sendLine(Self.makeErrorResponse(requestID: requestID, message: error.localizedDescription), over: connection)
        }
    }

    private func process(
        _ request: LoomBootstrapControlRequest,
        peer: LoomBootstrapControlPeer
    ) async throws -> LoomBootstrapControlResult {
        switch request.operation {
        case .status:
            return try await statusHandler(peer)
        case .submitCredentials:
            guard let credentialsPayload = request.credentialsPayload else {
                throw LoomBootstrapControlError.protocolViolation("Missing encrypted credentials payload.")
            }
            let credentials = try LoomBootstrapControlSecurity.decryptCredentials(
                credentialsPayload,
                sharedSecret: controlAuthSecret,
                requestID: request.requestID,
                timestampMs: request.auth.timestampMs,
                nonce: request.auth.nonce
            )
            return try await unlockHandler(peer, credentials)
        }
    }

    private func validate(
        _ request: LoomBootstrapControlRequest,
        endpoint: String
    ) async throws -> LoomBootstrapControlPeer {
        let derivedKeyID = LoomIdentityManager.keyID(for: request.auth.publicKey)
        guard derivedKeyID == request.auth.keyID else {
            throw LoomBootstrapControlError.protocolViolation("Bootstrap control key identifier mismatch.")
        }

        guard await replayProtector.validate(
            timestampMs: request.auth.timestampMs,
            nonce: request.auth.nonce
        ) else {
            throw LoomBootstrapControlError.protocolViolation("Bootstrap control replay rejected.")
        }

        let encryptedSHA256 = LoomBootstrapControlSecurity.payloadSHA256Hex(request.credentialsPayload?.combined)
        let payload = try LoomBootstrapControlSecurity.canonicalPayload(
            requestID: request.requestID,
            operation: request.operation,
            encryptedPayloadSHA256: encryptedSHA256,
            keyID: request.auth.keyID,
            timestampMs: request.auth.timestampMs,
            nonce: request.auth.nonce
        )
        guard LoomBootstrapIdentityVerification.verify(
            signature: request.auth.signature,
            payload: payload,
            publicKey: request.auth.publicKey
        ) else {
            throw LoomBootstrapControlError.protocolViolation("Bootstrap control signature verification failed.")
        }

        return LoomBootstrapControlPeer(
            keyID: request.auth.keyID,
            publicKey: request.auth.publicKey,
            endpoint: endpoint
        )
    }

    private func awaitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = BootstrapServerReadyContinuationBox(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.complete(.success(()))
                case let .failed(error):
                    completion.complete(.failure(LoomBootstrapControlError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    completion.complete(.failure(LoomBootstrapControlError.connectionFailed("Connection cancelled.")))
                default:
                    break
                }
            }
        }
    }

    private func sendLine<T: Encodable>(_ value: T, over connection: NWConnection) async throws {
        var payload = try JSONEncoder().encode(value)
        payload.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LoomBootstrapControlError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveLine(
        over connection: NWConnection,
        maxBytes: Int
    ) async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: LoomBootstrapControlError.connectionFailed(error.localizedDescription))
                        return
                    }
                    if let data {
                        continuation.resume(returning: data)
                        return
                    }
                    if isComplete {
                        continuation.resume(returning: Data())
                        return
                    }
                    continuation.resume(throwing: LoomBootstrapControlError.connectionFailed("No request data received."))
                }
            }

            if chunk.isEmpty {
                throw LoomBootstrapControlError.connectionFailed("Connection closed by client.")
            }

            buffer.append(chunk)
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[..<newlineIndex])
            }
            if buffer.count > maxBytes {
                throw LoomBootstrapControlError.protocolViolation("Bootstrap control request exceeded \(maxBytes) bytes.")
            }
        }
    }

    private nonisolated static func makeErrorResponse(
        requestID: UUID?,
        message: String?
    ) -> LoomBootstrapControlResponse {
        LoomBootstrapControlResponse(
            requestID: requestID ?? UUID(),
            success: false,
            availability: .unavailable,
            message: message,
            canRetry: false,
            retriesRemaining: nil,
            retryAfterSeconds: nil
        )
    }

    private nonisolated static func extractRequestID(from data: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let rawRequestID = dictionary["requestID"] as? String else {
            return nil
        }
        return UUID(uuidString: rawRequestID)
    }
}

private final class BootstrapServerReadyContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
