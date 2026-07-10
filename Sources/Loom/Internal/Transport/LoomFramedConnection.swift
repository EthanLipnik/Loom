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
    private let receiveBuffer: LoomFramedReceiveBuffer
    private let incompleteFrameTimeout: Duration
    package let receiveSemantics: LoomSessionReceiveSemantics = .singleLane

    package init(
        connection: NWConnection,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        incompleteFrameTimeout: Duration = .seconds(60)
    ) {
        self.connection = connection
        receiveBuffer = LoomFramedReceiveBuffer(
            retainedCapacityBudget: retainedCapacityBudget
        )
        self.incompleteFrameTimeout = max(.milliseconds(1), incompleteFrameTimeout)
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
        let frame: Data
        do {
            frame = try framedData(for: data)
        } catch {
            onComplete(error)
            return
        }
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

    package func closeTransport() async {
        await cancelPendingUnreliableSends()
        receiveBuffer.discard()
        connection.cancel()
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
        let frame = try framedData(for: data)
        try await send(frame)
    }

    private func framedData(for data: Data) throws -> Data {
        guard data.count <= LoomMessageLimits.maxFrameBytes,
              let payloadLength = UInt32(exactly: data.count) else {
            throw LoomError.protocolError(
                "Outgoing Loom frame exceeds the framed transport wire limit."
            )
        }
        var frame = Data(capacity: 4 + data.count)
        let length = payloadLength.bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(data)
        return frame
    }

    package func readFrame(maxBytes: Int = 1_048_576) async throws -> Data {
        guard maxBytes >= 0 else {
            throw LoomError.protocolError("Loom frame receive limit must not be negative.")
        }
        let effectiveMaximumBytes = min(maxBytes, LoomMessageLimits.maxFrameBytes)
        var incompleteFrameDeadline: ContinuousClock.Instant?

        do {
            while receiveBuffer.count < MemoryLayout<UInt32>.size {
                try await appendChunk(
                    maximumBytes: MemoryLayout<UInt32>.size - receiveBuffer.count,
                    deadline: incompleteFrameDeadline
                )
                if incompleteFrameDeadline == nil {
                    incompleteFrameDeadline = .now + incompleteFrameTimeout
                }
            }

            let length = try receiveBuffer.declaredPayloadLength()
            guard length <= effectiveMaximumBytes else {
                throw LoomError.protocolError(
                    "Received Loom frame larger than \(effectiveMaximumBytes) bytes."
                )
            }
            let requiredBytes = MemoryLayout<UInt32>.size + length
            while receiveBuffer.count < requiredBytes {
                try await appendChunk(
                    maximumBytes: min(65_536, requiredBytes - receiveBuffer.count),
                    deadline: incompleteFrameDeadline
                )
            }

            return try receiveBuffer.consumeCompleteFrame(requiredBytes: requiredBytes)
        } catch {
            receiveBuffer.discard()
            connection.cancel()
            throw error
        }
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

    private func appendChunk(
        maximumBytes: Int,
        deadline: ContinuousClock.Instant?
    ) async throws {
        let chunk: Data
        if let deadline {
            chunk = try await withLoomThrowingDeadline(
                deadline,
                onTimeout: { [connection] in
                    connection.cancel()
                },
                timeoutError: {
                    LoomError.protocolError("Timed out while receiving an incomplete Loom frame.")
                },
                operation: { [connection] in
                    try await Self.receiveChunk(
                        from: connection,
                        maximumLength: maximumBytes
                    )
                }
            )
        } else {
            chunk = try await Self.receiveChunk(
                from: connection,
                maximumLength: maximumBytes
            )
        }
        if chunk.isEmpty {
            throw LoomError.connectionFailed(
                LoomConnectionFailure(reason: .closed, detail: "Connection closed by peer.")
            )
        }
        try Task.checkCancellation()
        try receiveBuffer.append(chunk)
    }

    private nonisolated static func receiveChunk(
        from connection: NWConnection,
        maximumLength: Int
    ) async throws -> Data {
        guard maximumLength > 0 else {
            throw LoomError.protocolError("Invalid Loom framed receive length.")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
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
