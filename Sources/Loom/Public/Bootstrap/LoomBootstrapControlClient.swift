//
//  LoomBootstrapControlClient.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Runtime for bootstrap control handoff.
//

import Foundation
import Network

/// Control-channel runtime failures for daemon handoff.
public enum LoomBootstrapControlError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case missingAuthSecret
    case timedOut
    case connectionFailed(String)
    case protocolViolation(String)
    case requestRejected(String)

    /// A user-presentable reason for the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Bootstrap control endpoint is invalid."
        case .missingAuthSecret:
            "Bootstrap control requires an auth secret from peer metadata."
        case .timedOut:
            "Bootstrap control request timed out."
        case let .connectionFailed(detail):
            "Bootstrap control connection failed: \(detail)"
        case let .protocolViolation(detail):
            "Bootstrap control protocol error: \(detail)"
        case let .requestRejected(detail):
            "Bootstrap daemon rejected credential submission: \(detail)"
        }
    }
}

/// Daemon handoff result.
public struct LoomBootstrapControlResult: Sendable, Equatable {
    /// Whether the requested operation succeeded.
    public let success: Bool
    /// Current peer session state after the control request.
    public let state: LoomSessionAvailability
    /// Optional peer diagnostic message.
    public let message: String?
    /// Whether the request can be retried.
    public let canRetry: Bool
    /// Remaining retries available (if bounded by peer policy).
    public let retriesRemaining: Int?
    /// Cooldown before retry is allowed.
    public let retryAfterSeconds: Int?
    /// Whether the peer has an active post-unlock session.
    public var isSessionActive: Bool { state.isReady }

    public init(
        state: LoomSessionAvailability,
        message: String?,
        success: Bool = true,
        canRetry: Bool? = nil,
        retriesRemaining: Int? = nil,
        retryAfterSeconds: Int? = nil
    ) {
        self.success = success
        self.state = state
        self.message = message
        self.canRetry = canRetry ?? !state.isReady
        self.retriesRemaining = retriesRemaining
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Cross-platform bootstrap control contract for daemon handoff and unlock requests.
@available(*, deprecated, message: "Bootstrap control is weaker than SSH host-certificate bootstrap. Prefer LoomSSHBootstrapClient with LoomSSHServerTrustConfiguration.")
public protocol LoomBootstrapControlClient: Sendable {
    func requestStatus(
        endpoint: LoomBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        timeout: Duration
    ) async throws -> LoomBootstrapControlResult

    func requestUnlock(
        endpoint: LoomBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        username: String,
        password: String,
        timeout: Duration
    ) async throws -> LoomBootstrapControlResult
}

/// Default bootstrap control transport based on a single line-delimited TCP request/response.
@available(*, deprecated, message: "Bootstrap control is weaker than SSH host-certificate bootstrap. Prefer LoomSSHBootstrapClient with LoomSSHServerTrustConfiguration.")
public struct LoomDefaultBootstrapControlClient: LoomBootstrapControlClient {
    private let fetchIdentity: @Sendable () async throws -> LoomAccountIdentity
    private let signPayload: @Sendable (Data) async throws -> Data

    public init() {
        fetchIdentity = {
            try await MainActor.run {
                try LoomIdentityManager.shared.currentIdentity()
            }
        }
        signPayload = { payload in
            try await MainActor.run {
                try LoomIdentityManager.shared.sign(payload)
            }
        }
    }

    public init(identityManager: LoomIdentityManager) {
        fetchIdentity = {
            try await MainActor.run {
                try identityManager.currentIdentity()
            }
        }
        signPayload = { payload in
            try await MainActor.run {
                try identityManager.sign(payload)
            }
        }
    }

    public func requestStatus(
        endpoint: LoomBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        timeout: Duration
    )
    async throws -> LoomBootstrapControlResult {
        let request = try await makeAuthenticatedRequest(
            operation: .status,
            controlAuthSecret: controlAuthSecret,
            credentialsPayload: nil
        )
        let response = try await sendRequest(
            request,
            endpoint: endpoint,
            controlPort: controlPort,
            timeout: timeout
        )
        return LoomBootstrapControlResult(
            state: response.availability,
            message: response.message,
            success: response.success,
            canRetry: response.canRetry,
            retriesRemaining: response.retriesRemaining,
            retryAfterSeconds: response.retryAfterSeconds
        )
    }

    public func requestUnlock(
        endpoint: LoomBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        username: String,
        password: String,
        timeout: Duration
    )
    async throws -> LoomBootstrapControlResult {
        let trimmedSecret = password.trimmingCharacters(in: .newlines)
        guard !trimmedSecret.isEmpty else {
            throw LoomBootstrapControlError.protocolViolation("Credential secret is empty.")
        }

        let requestID = UUID()
        let timestampMs = LoomIdentitySigning.currentTimestampMs()
        let nonce = UUID().uuidString.lowercased()
        let credentials = LoomBootstrapCredentials(
            userIdentifier: username,
            secret: trimmedSecret
        )
        let encryptedPayload = try LoomBootstrapControlSecurity.encryptCredentials(
            credentials,
            sharedSecret: controlAuthSecret,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let request = try await makeAuthenticatedRequest(
            operation: .submitCredentials,
            controlAuthSecret: controlAuthSecret,
            credentialsPayload: encryptedPayload,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )

        let response = try await sendRequest(
            request,
            endpoint: endpoint,
            controlPort: controlPort,
            timeout: timeout
        )

        guard response.success else {
            throw LoomBootstrapControlError.requestRejected(response.message ?? "Credential submission rejected.")
        }

        return LoomBootstrapControlResult(
            state: response.availability,
            message: response.message,
            success: response.success,
            canRetry: response.canRetry,
            retriesRemaining: response.retriesRemaining,
            retryAfterSeconds: response.retryAfterSeconds
        )
    }
}

private extension LoomDefaultBootstrapControlClient {
    func makeAuthenticatedRequest(
        operation: LoomBootstrapControlOperation,
        controlAuthSecret: String,
        credentialsPayload: LoomBootstrapEncryptedCredentialsPayload?,
        requestID: UUID = UUID(),
        timestampMs: Int64 = LoomIdentitySigning.currentTimestampMs(),
        nonce: String = UUID().uuidString.lowercased()
    ) async throws -> LoomBootstrapControlRequest {
        let trimmedSecret = controlAuthSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            throw LoomBootstrapControlError.missingAuthSecret
        }
        guard nonce.utf8.count <= LoomMessageLimits.maxReplayNonceLength else {
            throw LoomBootstrapControlError.protocolViolation("Bootstrap control nonce is too long.")
        }

        let identity = try await fetchIdentity()
        let encryptedSHA256 = LoomBootstrapControlSecurity.payloadSHA256Hex(credentialsPayload?.combined)
        let payload = try LoomBootstrapControlSecurity.canonicalPayload(
            requestID: requestID,
            operation: operation,
            encryptedPayloadSHA256: encryptedSHA256,
            keyID: identity.keyID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let signature = try await signPayload(payload)
        let auth = LoomBootstrapControlAuthEnvelope(
            keyID: identity.keyID,
            publicKey: identity.publicKey,
            timestampMs: timestampMs,
            nonce: nonce,
            signature: signature
        )

        return LoomBootstrapControlRequest(
            requestID: requestID,
            operation: operation,
            auth: auth,
            credentialsPayload: credentialsPayload
        )
    }

    func sendRequest(
        _ request: LoomBootstrapControlRequest,
        endpoint: LoomBootstrapEndpoint,
        controlPort: UInt16,
        timeout: Duration
    )
    async throws -> LoomBootstrapControlResponse {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, controlPort > 0 else { throw LoomBootstrapControlError.invalidEndpoint }

        let timeoutNanoseconds = timeoutNanoseconds(timeout)
        guard timeoutNanoseconds > 0 else { throw LoomBootstrapControlError.timedOut }
        let timeoutDuration = Duration.nanoseconds(Int64(clamping: timeoutNanoseconds))

        return try await withThrowingTaskGroup(of: LoomBootstrapControlResponse.self) { group in
            group.addTask {
                try await performRequest(
                    request,
                    host: host,
                    port: controlPort
                )
            }
            group.addTask {
                try await Task.sleep(for: timeoutDuration)
                throw LoomBootstrapControlError.timedOut
            }

            guard let first = try await group.next() else {
                throw LoomBootstrapControlError.connectionFailed("Missing control response.")
            }
            group.cancelAll()
            return first
        }
    }

    func performRequest(
        _ request: LoomBootstrapControlRequest,
        host: String,
        port: UInt16
    ) async throws -> LoomBootstrapControlResponse {
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
        connection.start(queue: .global(qos: .utility))
        defer { connection.cancel() }

        try await awaitReady(connection)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try await send(data: payload, over: connection)

        let line = try await receiveLine(
            over: connection,
            maxBytes: LoomMessageLimits.maxBootstrapControlLineBytes
        )
        let response = try JSONDecoder().decode(LoomBootstrapControlResponse.self, from: line)
        guard response.requestID == request.requestID else {
            throw LoomBootstrapControlError.protocolViolation("Mismatched response request ID.")
        }
        return response
    }

    func awaitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ReadyContinuationBox(continuation: continuation)

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

    func send(data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LoomBootstrapControlError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receiveLine(
        over connection: NWConnection,
        maxBytes: Int
    )
    async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try await receiveChunk(over: connection)
            if chunk.isEmpty {
                throw LoomBootstrapControlError.connectionFailed("Connection closed by daemon.")
            }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[..<newlineIndex])
            }

            if buffer.count > maxBytes {
                throw LoomBootstrapControlError.protocolViolation("Response exceeded \(maxBytes) bytes.")
            }
        }
    }

    func receiveChunk(over connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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

                continuation.resume(throwing: LoomBootstrapControlError.connectionFailed("No response data received."))
            }
        }
    }

    func timeoutNanoseconds(_ timeout: Duration) -> UInt64 {
        let components = timeout.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let secondNanos = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let fractionalNanos = UInt64(attoseconds / 1_000_000_000)
        if secondNanos.overflow {
            return UInt64.max
        }
        let total = secondNanos.partialValue.addingReportingOverflow(fractionalNanos)
        return total.overflow ? UInt64.max : total.partialValue
    }
}

private final class ReadyContinuationBox: @unchecked Sendable {
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
