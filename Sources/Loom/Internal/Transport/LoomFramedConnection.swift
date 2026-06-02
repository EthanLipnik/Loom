//
//  LoomFramedConnection.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Network
import Dispatch

package actor LoomFramedConnection: LoomSessionTransport {
    private let connection: NWConnection
    private var queuedUnreliableSenders: [LoomQueuedUnreliableSendProfile: LoomOrderedUnreliableSendQueue] = [:]
    private var receiveBuffer = Data()
    package let receiveSemantics: LoomSessionReceiveSemantics = .singleLane

    package init(connection: NWConnection) {
        self.connection = connection
    }

    package func sendMessage(_ data: Data) async throws {
        try await sendFrame(data)
    }

    package func receiveMessage(maxBytes: Int) async throws -> Data {
        try await readFrame(maxBytes: maxBytes)
    }

    package func sendHandshakeMessage(_ data: Data) async throws {
        try await sendMessage(data)
    }

    package func receiveHandshakeMessage(maxBytes: Int) async throws -> Data {
        try await receiveMessage(maxBytes: maxBytes)
    }

    package func sendUnreliable(_ data: Data) async throws {
        try await sendFrame(data)
    }

    package func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile,
        options: LoomQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) async {
        let frame = framedData(for: data)
        queuedUnreliableSender(for: profile).enqueue(frame, options: options) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop {
                onComplete(drop)
            } else if let error {
                onComplete(LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
            } else {
                onComplete(nil)
            }
        }
    }

    package func resetQueuedUnreliableSends(
        profile: LoomQueuedUnreliableSendProfile
    ) async {
        queuedUnreliableSenders.removeValue(forKey: profile)?.close()
    }

    package func consumeQueuedUnreliableSendDiagnostics(
        profile: LoomQueuedUnreliableSendProfile
    ) async -> LoomQueuedUnreliableSendDiagnostics? {
        queuedUnreliableSenders[profile]?.consumeDiagnosticsSnapshot()
    }

    package func receiveUnreliable(maxBytes: Int) async throws -> Data {
        try await readFrame(maxBytes: maxBytes)
    }

    package func receivePriorityUnreliable(maxBytes: Int) async throws -> Data {
        throw LoomError.protocolError("Priority unreliable receive is only available on UDP transports.")
    }

    package func cancelPendingUnreliableSends() async {
        for sender in queuedUnreliableSenders.values {
            sender.close()
        }
    }

    private func queuedUnreliableSender(
        for profile: LoomQueuedUnreliableSendProfile
    ) -> LoomOrderedUnreliableSendQueue {
        if let existing = queuedUnreliableSenders[profile] {
            return existing
        }

        let limits = LoomOrderedUnreliableSendQueue.limits(for: profile)
        let sender = LoomOrderedUnreliableSendQueue(
            connection: connection,
            queue: DispatchQueue(
                label: "loom.framed.unreliable.send.\(profile.rawValue)",
                qos: .userInteractive
            ),
            maxOutstandingPackets: limits.maxOutstandingPackets,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            maxQueuedPackets: limits.maxQueuedPackets,
            replacesQueuedSends: limits.replacesQueuedSends,
            profile: profile,
            diagnosticsLabel: profile.rawValue
        )
        queuedUnreliableSenders[profile] = sender
        return sender
    }

    package func startAndAwaitReady(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = LoomReadyContinuationBox(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.complete(.success(()))
                case let .failed(error):
                    completion.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                case .cancelled:
                    completion.complete(
                        .failure(
                            LoomError.connectionFailed(
                                LoomConnectionFailure(reason: .cancelled, detail: "Connection cancelled.")
                            )
                        )
                    )
                case .waiting(let error):
                    LoomLogger.transport("TCP/QUIC connection waiting: \(error)")
                    if Self.shouldFailAfterWaiting(error) {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            completion.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                        }
                    }
                default:
                    break
                }
            }
            // Handler is set — now start. All state transitions are captured.
            connection.start(queue: queue)
        }
    }

    package nonisolated static func shouldFailAfterWaiting(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return ([.ENETDOWN, .EHOSTUNREACH, .ENETUNREACH, .ENOTCONN] as [POSIXErrorCode]).contains(code)
    }

    package func sendFrame(_ data: Data) async throws {
        let frame = framedData(for: data)
        try await send(frame)
    }

    private func framedData(for data: Data) -> Data {
        var frame = Data(capacity: 4 + data.count)
        let length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(data)
        return frame
    }

    package func readFrame(maxBytes: Int = 1_048_576) async throws -> Data {
        while receiveBuffer.count < 4 {
            try await appendChunk()
        }

        let length =
            (UInt32(receiveBuffer[0]) << 24) |
            (UInt32(receiveBuffer[1]) << 16) |
            (UInt32(receiveBuffer[2]) << 8) |
            UInt32(receiveBuffer[3])
        guard length <= UInt32(maxBytes) else {
            throw LoomError.protocolError("Received Loom frame larger than \(maxBytes) bytes.")
        }
        let requiredBytes = 4 + Int(length)
        while receiveBuffer.count < requiredBytes {
            try await appendChunk()
        }

        let payload = Data(receiveBuffer[4..<requiredBytes])
        receiveBuffer.removeSubrange(0..<requiredBytes)
        return payload
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func appendChunk() async throws {
        let chunk = try await receiveChunk()
        if chunk.isEmpty {
            throw LoomError.connectionFailed(
                LoomConnectionFailure(reason: .closed, detail: "Connection closed by peer.")
            )
        }
        receiveBuffer.append(chunk)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
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
                continuation.resume(throwing: LoomError.protocolError("No data received from connection."))
            }
        }
    }
}

private final class LoomReadyContinuationBox: @unchecked Sendable {
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
