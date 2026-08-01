//
//  LoomFramedConnection.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Dispatch
import LoomNetworking

package actor LoomFramedConnection: LoomSessionTransport {
    private let connection: any LoomNetworkConnection
    private let serializedUnreliableSender: LoomSerializedNetworkSendQueue
    private var queuedUnreliableSenders: [LoomQueuedUnreliableSendProfile: LoomOrderedUnreliableSendQueue] = [:]
    private var observationTask: Task<Void, Never>?
    private let receiveBuffer: LoomFramedReceiveBuffer
    private let incompleteFrameTimeout: Duration
    private var incompleteFrameDeadline: ContinuousClock.Instant?
    package let receiveSemantics: LoomSessionReceiveSemantics = .singleLane

    package init(
        connection: any LoomNetworkConnection,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        incompleteFrameTimeout: Duration = .seconds(60)
    ) {
        self.connection = connection
        serializedUnreliableSender = LoomSerializedNetworkSendQueue(connection: connection)
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

    package func receiveMessageBatch(
        maxBytes: Int,
        maximumMessages: Int
    ) async throws -> [Data] {
        try await readFrames(maxBytes: maxBytes, maximumFrames: maximumMessages)
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

    package func sendUnreliableQueuedBatch(
        _ items: [LoomQueuedUnreliableBatchItem],
        profile: LoomQueuedUnreliableSendProfile
    ) async {
        guard !items.isEmpty else { return }
        var frames: [LoomQueuedUnreliableBatchItem] = []
        frames.reserveCapacity(items.count)
        do {
            for item in items {
                frames.append(LoomQueuedUnreliableBatchItem(
                    data: try framedData(for: item.data),
                    options: item.options,
                    onComplete: { error in
                        if let drop = error as? LoomQueuedUnreliableSendDrop {
                            item.onComplete(drop)
                        } else if let error {
                            item.onComplete(LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
                        } else {
                            item.onComplete(nil)
                        }
                    }
                ))
            }
        } catch {
            for item in items {
                item.onComplete(error)
            }
            return
        }
        await withCheckedContinuation { continuation in
            queuedUnreliableSender(for: profile).enqueueBatch(frames) {
                continuation.resume()
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

    package func receiveUnreliableBatch(
        maxBytes: Int,
        maximumMessages: Int
    ) async throws -> [Data] {
        try await readFrames(maxBytes: maxBytes, maximumFrames: maximumMessages)
    }

    package func receivePriorityUnreliable(maxBytes: Int) async throws -> Data {
        throw LoomError.protocolError("Priority unreliable receive is only available on UDP transports.")
    }

    package func cancelPendingUnreliableSends() async {
        for sender in queuedUnreliableSenders.values {
            sender.close()
        }
        serializedUnreliableSender.close()
        observationTask?.cancel()
    }

    package func closeTransport() async {
        await cancelPendingUnreliableSends()
        serializedUnreliableSender.close()
        observationTask?.cancel()
        observationTask = nil
        receiveBuffer.discard()
        incompleteFrameDeadline = nil
        await connection.cancel()
    }

    package func hardCloseTransport() async {
        await cancelPendingUnreliableSends()
        serializedUnreliableSender.close()
        observationTask?.cancel()
        observationTask = nil
        receiveBuffer.discard()
        incompleteFrameDeadline = nil
        await connection.hardCancel()
    }

    private func queuedUnreliableSender(
        for profile: LoomQueuedUnreliableSendProfile
    ) -> LoomOrderedUnreliableSendQueue {
        if let existing = queuedUnreliableSenders[profile] {
            return existing
        }

        let limits = LoomOrderedUnreliableSendQueue.limits(for: profile)
        let sender = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(
                label: "loom.framed.unreliable.send.\(profile.rawValue)",
                qos: .userInteractive
            ),
            maxOutstandingPackets: limits.maxOutstandingPackets,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            maxQueuedPackets: limits.maxQueuedPackets,
            replacesQueuedSends: limits.replacesQueuedSends,
            profile: profile,
            diagnosticsLabel: profile.rawValue,
            sendOperation: { [connection, serializedUnreliableSender] data, onComplete in
#if canImport(Network)
                if let concurrentConnection = connection as? any LoomConcurrentQueuedSendConnection {
                    concurrentConnection.sendQueued(data, completion: onComplete)
                    return
                }
#endif
                serializedUnreliableSender.enqueue(data, completion: onComplete)
            }
        )
        queuedUnreliableSenders[profile] = sender
        return sender
    }

    package func startAndAwaitReady(queue: DispatchQueue) async throws {
        do {
            try await connection.start()
        } catch {
            throw LoomError.connectionFailed(LoomConnectionFailure.classify(error))
        }
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
        guard let frame = try await readFrames(maxBytes: maxBytes, maximumFrames: 1).first else {
            throw LoomError.protocolError("Framed receive returned an empty batch.")
        }
        return frame
    }

    package func readFrames(
        maxBytes: Int = 1_048_576,
        maximumFrames: Int
    ) async throws -> [Data] {
        guard maxBytes >= 0 else {
            throw LoomError.protocolError("Loom frame receive limit must not be negative.")
        }
        guard maximumFrames > 0 else {
            throw LoomError.protocolError("Loom frame receive batch size must be positive.")
        }
        let effectiveMaximumBytes = min(maxBytes, LoomMessageLimits.maxFrameBytes)
        var frames: [Data] = []
        frames.reserveCapacity(min(maximumFrames, 64))

        do {
            while frames.isEmpty {
                while receiveBuffer.count >= MemoryLayout<UInt32>.size,
                      frames.count < maximumFrames {
                    let length = try receiveBuffer.declaredPayloadLength()
                    guard length <= effectiveMaximumBytes else {
                        throw LoomError.protocolError(
                            "Received Loom frame larger than \(effectiveMaximumBytes) bytes."
                        )
                    }
                    let requiredBytes = MemoryLayout<UInt32>.size + length
                    guard receiveBuffer.count >= requiredBytes else { break }
                    frames.append(try receiveBuffer.consumeCompleteFrame(requiredBytes: requiredBytes))
                    if receiveBuffer.count == 0 {
                        incompleteFrameDeadline = nil
                    }
                }

                guard frames.isEmpty else { break }
                try await appendChunk(
                    maximumBytes: min(
                        LoomFramedReceiveBuffer.maximumReadAheadBytes,
                        LoomFramedReceiveBuffer.maximumRetainedBytes - receiveBuffer.count
                    ),
                    deadline: incompleteFrameDeadline
                )
                if incompleteFrameDeadline == nil {
                    incompleteFrameDeadline = .now + incompleteFrameTimeout
                }
            }

            return frames
        } catch {
            receiveBuffer.discard()
            incompleteFrameDeadline = nil
            await connection.cancel()
            throw error
        }
    }

    private func send(_ data: Data) async throws {
        do {
            try await connection.send(data)
        } catch {
            throw LoomError.connectionFailed(LoomConnectionFailure.classify(error))
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
                    Task {
                        await connection.cancel()
                    }
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
        from connection: any LoomNetworkConnection,
        maximumLength: Int
    ) async throws -> Data {
        guard maximumLength > 0 else {
            throw LoomError.protocolError("Invalid Loom framed receive length.")
        }
        do {
            return try await connection.receive(maximumBytes: maximumLength) ?? Data()
        } catch {
            throw LoomError.connectionFailed(LoomConnectionFailure.classify(error))
        }
    }

    package func setObservationHandler(
        _ handler: (@Sendable (LoomSessionTransportObservation) -> Void)?
    ) async {
        observationTask?.cancel()
        observationTask = nil
        guard let handler else { return }
        let events = await connection.makeEventStream()
        observationTask = Task {
            for await event in events {
                guard !Task.isCancelled else { break }
                switch event {
                case let .path(path):
                    handler(.path(path))
                case let .failed(error):
                    handler(.failed(error.detail))
                case .cancelled:
                    handler(.cancelled)
                }
            }
        }
    }
}
