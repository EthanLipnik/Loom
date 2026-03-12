//
//  LoomBootstrapControlServerTests.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

@testable import Loom
import Foundation
import Network
import Testing

@Suite("Loom Bootstrap Control Server", .serialized)
struct LoomBootstrapControlServerTests {
    @MainActor
    @Test("Server status and unlock handlers round-trip through the client")
    func statusAndUnlockRoundTrip() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.bootstrap-control.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let server = LoomBootstrapControlServer(
            controlAuthSecret: "server-secret",
            onStatus: { peer in
                #expect(!peer.keyID.isEmpty)
                return LoomBootstrapControlResult(state: .credentialsRequired, message: "unlock needed")
            },
            onUnlock: { peer, credentials in
                #expect(!peer.keyID.isEmpty)
                #expect(credentials.userIdentifier == "ethan")
                #expect(credentials.secret == "hunter2")
                return LoomBootstrapControlResult(state: .ready, message: "ready")
            }
        )
        let port = try await server.start(port: 0)
        defer {
            Task {
                await server.stop()
            }
        }

        let endpoint = LoomBootstrapEndpoint(host: "127.0.0.1", port: 22, source: .user)
        let client = LoomDefaultBootstrapControlClient(identityManager: identityManager)

        let status = try await client.requestStatus(
            endpoint: endpoint,
            controlPort: port,
            controlAuthSecret: "server-secret",
            timeout: .seconds(5)
        )
        #expect(status.state == .credentialsRequired)
        #expect(status.message == "unlock needed")

        let unlock = try await client.requestUnlock(
            endpoint: endpoint,
            controlPort: port,
            controlAuthSecret: "server-secret",
            username: "ethan",
            password: "hunter2",
            timeout: .seconds(5)
        )
        #expect(unlock.state == .ready)
        #expect(unlock.message == "ready")
    }

    @MainActor
    @Test("Unlock failures preserve the request ID and surface as request rejection")
    func unlockFailurePreservesRequestID() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.bootstrap-control.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let server = LoomBootstrapControlServer(
            controlAuthSecret: "server-secret",
            onStatus: { _ in
                LoomBootstrapControlResult(state: .credentialsRequired, message: "unlock needed")
            },
            onUnlock: { _, _ in
                Issue.record("Unlock handler should not run when decryption fails.")
                return LoomBootstrapControlResult(state: .ready, message: "unexpected")
            }
        )
        let port = try await server.start(port: 0)
        defer {
            Task {
                await server.stop()
            }
        }

        let endpoint = LoomBootstrapEndpoint(host: "127.0.0.1", port: 22, source: .user)
        let client = LoomDefaultBootstrapControlClient(identityManager: identityManager)

        do {
            _ = try await client.requestUnlock(
                endpoint: endpoint,
                controlPort: port,
                controlAuthSecret: "wrong-secret",
                username: "ethan",
                password: "hunter2",
                timeout: .seconds(5)
            )
            Issue.record("Expected requestUnlock to reject a decrypt failure.")
        } catch let error as LoomBootstrapControlError {
            switch error {
            case let .requestRejected(message):
                #expect(!message.isEmpty)
            default:
                Issue.record("Expected requestRejected, got \(error.localizedDescription).")
            }
        } catch {
            Issue.record("Expected LoomBootstrapControlError, got \(error.localizedDescription).")
        }
    }

    @MainActor
    @Test("Malformed requests preserve request IDs on decode failures")
    func malformedRequestsPreserveRequestID() async throws {
        let server = LoomBootstrapControlServer(
            controlAuthSecret: "server-secret",
            onStatus: { _ in LoomBootstrapControlResult(state: .ready, message: "ready") },
            onUnlock: { _, _ in LoomBootstrapControlResult(state: .ready, message: "ready") }
        )
        let port = try await server.start(port: 0)
        defer {
            Task {
                await server.stop()
            }
        }

        let requestID = UUID()
        let response = try await sendRawRequest(
            port: port,
            payload: #"{"requestID":"\#(requestID.uuidString)","operation":42}"#
        )

        #expect(response.requestID == requestID)
        #expect(response.success == false)
    }

    @MainActor
    @Test("Validation failures preserve request IDs")
    func validationFailuresPreserveRequestID() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.bootstrap-control.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let server = LoomBootstrapControlServer(
            controlAuthSecret: "server-secret",
            onStatus: { _ in
                Issue.record("Status handler should not run when validation fails.")
                return LoomBootstrapControlResult(state: .ready, message: "unexpected")
            },
            onUnlock: { _, _ in
                LoomBootstrapControlResult(state: .ready, message: "unexpected")
            }
        )
        let port = try await server.start(port: 0)
        defer {
            Task {
                await server.stop()
            }
        }

        let requestID = UUID()
        let request = try await makeAuthenticatedStatusRequest(
            identityManager: identityManager,
            requestID: requestID,
            keyIDOverride: "invalid-key-id"
        )
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = try await sendRawRequest(port: port, payload: payload)

        #expect(response.requestID == requestID)
        #expect(response.success == false)
    }
}

@MainActor
private func makeAuthenticatedStatusRequest(
    identityManager: LoomIdentityManager,
    requestID: UUID,
    keyIDOverride: String? = nil
) async throws -> LoomBootstrapControlRequest {
    let identity = try identityManager.currentIdentity()
    let timestampMs = LoomIdentitySigning.currentTimestampMs()
    let nonce = UUID().uuidString.lowercased()
    let payload = try LoomBootstrapControlSecurity.canonicalPayload(
        requestID: requestID,
        operation: .status,
        encryptedPayloadSHA256: LoomBootstrapControlSecurity.payloadSHA256Hex(nil),
        keyID: keyIDOverride ?? identity.keyID,
        timestampMs: timestampMs,
        nonce: nonce
    )
    let signature = try identityManager.sign(payload)
    return LoomBootstrapControlRequest(
        requestID: requestID,
        operation: .status,
        auth: LoomBootstrapControlAuthEnvelope(
            keyID: keyIDOverride ?? identity.keyID,
            publicKey: identity.publicKey,
            timestampMs: timestampMs,
            nonce: nonce,
            signature: signature
        )
    )
}

private func sendRawRequest(
    port: UInt16,
    payload: String
) async throws -> LoomBootstrapControlResponse {
    let connection = NWConnection(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: port) ?? .any,
        using: .tcp
    )
    connection.start(queue: .global(qos: .utility))
    defer { connection.cancel() }

    try await awaitReady(connection)

    var data = Data(payload.utf8)
    data.append(0x0A)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
        })
    }

    let line = try await receiveLine(over: connection)
    return try JSONDecoder().decode(LoomBootstrapControlResponse.self, from: line)
}

private func awaitReady(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let box = TestReadyContinuationBox(continuation: continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.complete(.success(()))
            case let .failed(error):
                box.complete(.failure(error))
            case .cancelled:
                box.complete(.failure(LoomBootstrapControlError.connectionFailed("Connection cancelled.")))
            default:
                break
            }
        }
    }
}

private func receiveLine(over connection: NWConnection) async throws -> Data {
    var buffer = Data()
    while true {
        let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
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

        if chunk.isEmpty {
            throw LoomBootstrapControlError.connectionFailed("Connection closed by daemon.")
        }

        buffer.append(chunk)
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            return Data(buffer[..<newlineIndex])
        }
    }
}

private final class TestReadyContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume(returning: ())
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
