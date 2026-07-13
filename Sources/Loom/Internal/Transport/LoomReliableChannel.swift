//
//  LoomReliableChannel.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation
import LoomNetworking

#if canImport(Network)
package protocol LoomConcurrentQueuedSendConnection: LoomNetworkConnection {
    func sendQueued(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    )
}
#endif

/// Reliable datagram transport for Loom sessions over UDP.
///
/// Provides ordered, reliable delivery of arbitrary-size messages on top of an
/// a message-preserving datagram connection. Implements selective-ACK with piggyback
/// acknowledgments, automatic retransmission, and transparent fragmentation
/// for messages exceeding a single datagram.
package actor LoomReliableChannel: LoomSessionTransport {
    private let connection: any LoomNetworkConnection
    private let serializedUnreliableSender: LoomSerializedNetworkSendQueue
    private var queuedUnreliableSenders: [LoomQueuedUnreliableSendProfile: LoomOrderedUnreliableSendQueue] = [:]
    private var observationTask: Task<Void, Never>?
    package let receiveSemantics: LoomSessionReceiveSemantics = .independentReliableAndUnreliable

    // MARK: - Send State

    private var nextSequence: UInt32 = 0
    private var pendingAcks: [UInt32: PendingPacket] = [:]
    private var pendingAckByteCount = 0
    private var retryTimer: DispatchSourceTimer?
    private let sendQueue = DispatchQueue(label: "loom.reliable.send", qos: .userInteractive)

    // MARK: - Receive State

    private var highestContiguousReceived: UInt32 = 0
    private var receivedBeyondContiguous: Set<UInt32> = []
    private var hasReceivedFirstPacket = false
    private var fragments: [FragmentKey: FragmentAssembly] = [:]
    private var pendingFragmentCount = 0
    private var pendingFragmentByteCount = 0
    private let fragmentBudget: LoomIncomingRetainedCapacityBudget
    private var needsAck = false
    private var lastInboundPacketAt: CFAbsoluteTime?
    private var lastDedicatedAckSentAt: CFAbsoluteTime?

    // MARK: - Delivery

    private let orderedDeliveryBudget: LoomIncomingRetainedCapacityBudget
    private let deliveryBuffer: LoomBoundedIncomingDataBuffer
    private let deliveryStream: AsyncStream<Data>

    private let handshakeDeliveryBuffer: LoomBoundedIncomingDataBuffer
    private let handshakeDeliveryStream: AsyncStream<Data>
    private var routesReliablePacketsToHandshake = true

    private let unreliableDeliveryBuffer: LoomBoundedIncomingDataBuffer

    private let priorityUnreliableDeliveryBuffer: LoomBoundedIncomingDataBuffer
    private let priorityUnreliableDeliveryStream: AsyncStream<Data>
    private var droppedUnreliableDeliveryPayloadCount: UInt64 = 0
    private var lastUnreliableDeliveryDropLogAt: CFAbsoluteTime?

    // MARK: - Ordered Delivery

    private var nextDeliverySequence: UInt32 = 0
    private var hasSetInitialDeliverySequence = false
    private var pendingDelivery: [UInt32: PendingMessage] = [:]

    // MARK: - RTT Estimation

    private var smoothedRTT: Double = 0.2
    private var rttVariance: Double = 0.1
    private var rto: Double = 0.5

    // MARK: - Configuration

    private let maxRetries = 5
    private let ackCoalesceInterval: Double = 0.02
    private let fragmentPruneInterval: Double = 5.0
    private let immediateAckIdleThreshold: Double = 0.05
    private let recentInboundTimeoutGrace: Double = 20.0
    private let absolutePendingAckTimeout: Double = 30.0
    private let maxPendingFragmentAssemblies = 64
    private let maxPendingFragmentBytes = LoomMessageLimits.maxReceiveBufferBytes
    private let maxPendingFragments = 65_536
    private let maxPendingDeliveryMessages = LoomMessageLimits.maxBufferedPayloadsPerStream
    private let maxPendingDeliveryBytes = LoomMessageLimits.maxReceiveBufferBytes
    private let maxPendingReliablePackets: Int
    private let maxPendingReliableBytes: Int

    // MARK: - Lifecycle

    private var receiveTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var isClosed = false
    private var terminalFailure: LoomConnectionFailure?

    package init(
        connection: any LoomNetworkConnection,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        maximumPendingReliablePackets: Int = 8_192,
        maximumPendingReliableBytes: Int = 16 * 1024 * 1024
    ) {
        self.connection = connection
        serializedUnreliableSender = LoomSerializedNetworkSendQueue(connection: connection)
        maxPendingReliablePackets = max(1, maximumPendingReliablePackets)
        maxPendingReliableBytes = max(1, maximumPendingReliableBytes)
        fragmentBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: LoomMessageLimits.maxReceiveBufferBytes,
            maximumPayloadCount: 64,
            maximumBatchCount: 64,
            parent: retainedCapacityBudget
        )
        let orderedDeliveryBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: LoomMessageLimits.maxReceiveBufferBytes,
            maximumPayloadCount: LoomMessageLimits.maxBufferedPayloadsPerStream,
            maximumBatchCount: LoomMessageLimits.maxBufferedPayloadsPerStream,
            parent: retainedCapacityBudget
        )
        self.orderedDeliveryBudget = orderedDeliveryBudget
        let deliveryBuffer = LoomBoundedIncomingDataBuffer(
            maximumBufferedBytes: LoomMessageLimits.maxReceiveBufferBytes,
            maximumBufferedItems: LoomMessageLimits.maxBufferedPayloadsPerStream,
            retainedCapacityBudget: orderedDeliveryBudget
        )
        self.deliveryBuffer = deliveryBuffer
        deliveryStream = deliveryBuffer.makeStream()

        let handshakeDeliveryBuffer = Self.makeDeliveryBuffer(
            maximumBytes: LoomMessageLimits.maxHelloFrameBytes,
            maximumPayloads: 8,
            parent: retainedCapacityBudget
        )
        self.handshakeDeliveryBuffer = handshakeDeliveryBuffer
        handshakeDeliveryStream = handshakeDeliveryBuffer.makeStream()

        let unreliableDeliveryBuffer = Self.makeDeliveryBuffer(
            maximumBytes: 16 * 1024 * 1024,
            maximumPayloads: LoomMessageLimits.maxBufferedPayloadsPerSession,
            parent: retainedCapacityBudget
        )
        self.unreliableDeliveryBuffer = unreliableDeliveryBuffer

        let priorityUnreliableDeliveryBuffer = Self.makeDeliveryBuffer(
            maximumBytes: 8 * 1024 * 1024,
            maximumPayloads: LoomMessageLimits.maxBufferedPayloadsPerSession,
            parent: retainedCapacityBudget
        )
        self.priorityUnreliableDeliveryBuffer = priorityUnreliableDeliveryBuffer
        priorityUnreliableDeliveryStream = priorityUnreliableDeliveryBuffer.makeStream()
    }

    deinit {
        retryTimer?.cancel()
        receiveTask?.cancel()
        ackTask?.cancel()
        observationTask?.cancel()
        serializedUnreliableSender.close()
        deliveryBuffer.abort()
        handshakeDeliveryBuffer.abort()
        unreliableDeliveryBuffer.abort()
        priorityUnreliableDeliveryBuffer.abort()
    }

    // MARK: - LoomSessionTransport

    package func startAndAwaitReady(queue: DispatchQueue) async throws {
        do {
            try await connection.start()
        } catch {
            throw LoomError.connectionFailed(LoomConnectionFailure.classify(error))
        }
        startReceiveLoop()
        startRetryTimer()
    }

    package func sendMessage(_ data: Data) async throws {
        finishHandshakeDeliveryIfNeeded()
        try await sendReliableMessage(data)
    }

    package func sendHandshakeMessage(_ data: Data) async throws {
        try await sendReliableMessage(data, additionalFlags: .hello)
    }

    private func sendReliableMessage(
        _ data: Data,
        additionalFlags: LoomReliablePacketFlags = []
    ) async throws {
        guard !isClosed else {
            throw LoomError.protocolError("Reliable channel is closed.")
        }

        let fragmentPayload = loomReliableMaxFragmentPayload
        if data.count <= fragmentPayload {
            let seq = allocateSequence()
            var flags: LoomReliablePacketFlags = .reliable
            flags.formUnion(additionalFlags)
            let header = LoomReliablePacketHeader(
                flags: flags,
                sequence: seq,
                ackSequence: currentAckSequence(),
                ackBitmap: currentAckBitmap(),
                fragmentIndex: 0,
                fragmentCount: 1,
                payloadLength: UInt16(data.count)
            )
            let packet = header.serialize() + data
            try trackPending(seq: seq, packet: packet)
            try await sendRaw(packet)
        } else {
            let totalFragments = (data.count + fragmentPayload - 1) / fragmentPayload
            guard totalFragments <= Int(UInt16.max) else {
                throw LoomError.protocolError("Message too large to fragment (\(data.count) bytes).")
            }

            // Send fragments in batches with yields between batches to avoid
            // overwhelming the socket's kernel send buffer. Without
            // backpressure, ~950 fragments (for a 1MB payload) saturate the
            // UDP send buffer and cause the connection to be cancelled.
            let sendBatchSize = 16
            for i in 0..<totalFragments {
                let start = i * fragmentPayload
                let end = min(start + fragmentPayload, data.count)
                let chunk = data[start..<end]
                let seq = allocateSequence()
                var flags: LoomReliablePacketFlags = [.reliable, .fragment]
                flags.formUnion(additionalFlags)

                let header = LoomReliablePacketHeader(
                    flags: flags,
                    sequence: seq,
                    ackSequence: currentAckSequence(),
                    ackBitmap: currentAckBitmap(),
                    fragmentIndex: UInt16(i),
                    fragmentCount: UInt16(totalFragments),
                    payloadLength: UInt16(chunk.count)
                )
                let packet = header.serialize() + chunk
                try trackPending(seq: seq, packet: packet)
                try await sendRaw(packet)

                // Yield after each batch to let the kernel drain its send buffer.
                // Larger messages need more breathing room to avoid buffer saturation.
                if (i + 1) % sendBatchSize == 0, i + 1 < totalFragments {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
    }

    package func receiveMessage(maxBytes: Int) async throws -> Data {
        finishHandshakeDeliveryIfNeeded()
        for await message in deliveryStream {
            if message.count > maxBytes {
                throw LoomError.protocolError(
                    "Received message exceeds limit: \(message.count) > \(maxBytes)"
                )
            }
            return message
        }
        if let terminalFailure {
            throw LoomError.connectionFailed(terminalFailure)
        }
        throw LoomError.connectionFailed(
            LoomConnectionFailure(reason: .cancelled, detail: "Reliable channel cancelled.")
        )
    }

    package func receiveHandshakeMessage(maxBytes: Int) async throws -> Data {
        for await message in handshakeDeliveryStream {
            if message.count > maxBytes {
                throw LoomError.protocolError(
                    "Received handshake message exceeds limit: \(message.count) > \(maxBytes)"
                )
            }
            return message
        }
        if let terminalFailure {
            throw LoomError.connectionFailed(terminalFailure)
        }
        throw LoomError.connectionFailed(
            LoomConnectionFailure(reason: .cancelled, detail: "Reliable channel cancelled.")
        )
    }

    /// Send a message without requiring acknowledgment (fire-and-forget).
    /// Unreliable packets do not consume reliable sequence numbers and are
    /// never retransmitted.
    package func sendUnreliable(_ data: Data) async throws {
        guard !isClosed else { return }
        guard let payloadLength = UInt16(exactly: data.count) else {
            throw LoomError.protocolError("Unreliable UDP payload exceeds the wire length limit.")
        }

        let header = LoomReliablePacketHeader(
            flags: [],
            sequence: 0,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap(),
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: payloadLength
        )
        try await sendRaw(header.serialize() + data)
    }

    package func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile,
        options: LoomQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) async {
        guard !isClosed else {
            onComplete(LoomError.protocolError("Reliable channel is closed."))
            return
        }
        guard let payloadLength = UInt16(exactly: data.count) else {
            onComplete(LoomError.protocolError("Unreliable UDP payload exceeds the wire length limit."))
            return
        }

        let header = LoomReliablePacketHeader(
            flags: [],
            sequence: 0,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap(),
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: payloadLength
        )
        let packet = header.serialize() + data
        queuedUnreliableSender(for: profile).enqueue(packet, options: options) { error in
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
        guard let message = try await receiveUnreliableBatch(
            maxBytes: maxBytes,
            maximumMessages: 1
        ).first else {
            throw LoomError.connectionFailed(
                LoomConnectionFailure(reason: .cancelled, detail: "Reliable channel cancelled.")
            )
        }
        return message
    }

    package func receiveUnreliableBatch(
        maxBytes: Int,
        maximumMessages: Int
    ) async throws -> [Data] {
        guard maxBytes > 0, maximumMessages > 0 else {
            throw LoomError.protocolError("Invalid unreliable receive batch limit.")
        }
        let messages = await unreliableDeliveryBuffer.nextBatch(maximumCount: maximumMessages)
        for message in messages where message.count > maxBytes {
            throw LoomError.protocolError(
                "Received unreliable message exceeds limit: \(message.count) > \(maxBytes)"
            )
        }
        guard !messages.isEmpty else {
            if let terminalFailure {
                throw LoomError.connectionFailed(terminalFailure)
            }
            throw LoomError.connectionFailed(
                LoomConnectionFailure(reason: .cancelled, detail: "Reliable channel cancelled.")
            )
        }
        return messages
    }

    package func receivePriorityUnreliable(maxBytes: Int) async throws -> Data {
        for await message in priorityUnreliableDeliveryStream {
            if message.count > maxBytes {
                throw LoomError.protocolError(
                    "Received priority unreliable message exceeds limit: \(message.count) > \(maxBytes)"
                )
            }
            return message
        }
        if let terminalFailure {
            throw LoomError.connectionFailed(terminalFailure)
        }
        throw LoomError.connectionFailed(
            LoomConnectionFailure(reason: .cancelled, detail: "Reliable channel cancelled.")
        )
    }

    package func prepareUnreliableReceive(maxBytes: Int) async throws {
        guard maxBytes > 0 else {
            throw LoomError.protocolError("Invalid unreliable receive size limit.")
        }
        finishHandshakeDeliveryIfNeeded()
    }

    /// Moves the reliable receive lane out of hello-only routing without
    /// allowing a later post-handshake packet to become the ordering origin.
    /// A trust frame can arrive while its peer is still decoding the hello and
    /// is deliberately left unacknowledged for retransmission. Remembering the
    /// sequence immediately after the accepted hello makes a subsequently
    /// arriving key-confirmation frame wait for that trust-frame retransmit.
    private func finishHandshakeDeliveryIfNeeded() {
        guard routesReliablePacketsToHandshake else { return }
        routesReliablePacketsToHandshake = false
        guard hasReceivedFirstPacket else { return }
        nextDeliverySequence = highestContiguousReceived &+ 1
        hasSetInitialDeliverySequence = true
    }

    package func cancelPendingUnreliableSends() async {
        for sender in queuedUnreliableSenders.values {
            sender.close()
        }
    }

    package func closeTransport() async {
        await cancelPendingUnreliableSends()
        serializedUnreliableSender.close()
        observationTask?.cancel()
        observationTask = nil
        close()
        await connection.cancel()
    }

    package func close(with failure: LoomConnectionFailure? = nil) {
        guard !isClosed else { return }
        isClosed = true
        for sender in queuedUnreliableSenders.values {
            sender.close()
        }
        serializedUnreliableSender.close()
        if let failure {
            terminalFailure = failure
        } else if terminalFailure == nil {
            terminalFailure = LoomConnectionFailure(reason: .cancelled, detail: "Reliable channel cancelled.")
        }
        retryTimer?.cancel()
        receiveTask?.cancel()
        ackTask?.cancel()
        pendingAcks.removeAll(keepingCapacity: false)
        pendingAckByteCount = 0
        discardRetainedIncomingState()
        deliveryBuffer.abort()
        handshakeDeliveryBuffer.abort()
        unreliableDeliveryBuffer.abort()
        priorityUnreliableDeliveryBuffer.abort()
        Task { [connection] in
            await connection.cancel()
        }
    }

    private nonisolated static func makeDeliveryBuffer(
        maximumBytes: Int,
        maximumPayloads: Int,
        parent: LoomIncomingRetainedCapacityBudget?
    ) -> LoomBoundedIncomingDataBuffer {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: maximumBytes,
            maximumPayloadCount: maximumPayloads,
            maximumBatchCount: maximumPayloads,
            parent: parent
        )
        return LoomBoundedIncomingDataBuffer(
            maximumBufferedBytes: maximumBytes,
            maximumBufferedItems: maximumPayloads,
            retainedCapacityBudget: budget
        )
    }

    private func queuedUnreliableSender(
        for profile: LoomQueuedUnreliableSendProfile
    ) -> LoomOrderedUnreliableSendQueue {
        if let existing = queuedUnreliableSenders[profile] {
            return existing
        }

        let limits = LoomOrderedUnreliableSendQueue.limits(for: profile)
        let sendOperation: @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
        #if canImport(Network)
        if let concurrentConnection = connection as? any LoomConcurrentQueuedSendConnection {
            sendOperation = { [concurrentConnection] data, onComplete in
                concurrentConnection.sendQueued(data, completion: onComplete)
            }
        } else {
            sendOperation = { [serializedUnreliableSender] data, onComplete in
                serializedUnreliableSender.enqueue(data, completion: onComplete)
            }
        }
        #else
        sendOperation = { [serializedUnreliableSender] data, onComplete in
            serializedUnreliableSender.enqueue(data, completion: onComplete)
        }
        #endif
        let sender = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(
                label: "loom.reliable.unreliable.send.\(profile.rawValue)",
                qos: .userInteractive
            ),
            maxOutstandingPackets: limits.maxOutstandingPackets,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            maxQueuedPackets: limits.maxQueuedPackets,
            replacesQueuedSends: limits.replacesQueuedSends,
            profile: profile,
            diagnosticsLabel: profile.rawValue,
            sendOperation: sendOperation
        )
        queuedUnreliableSenders[profile] = sender
        return sender
    }

    // MARK: - Sequence Management

    private func allocateSequence() -> UInt32 {
        let seq = nextSequence
        nextSequence &+= 1
        return seq
    }

    // MARK: - Ack State

    private func currentAckSequence() -> UInt32 {
        highestContiguousReceived
    }

    private func currentAckBitmap() -> UInt32 {
        var bitmap: UInt32 = 0
        let base = highestContiguousReceived
        for seq in receivedBeyondContiguous {
            let diff = seq &- base
            if diff >= 1 && diff <= 32 {
                bitmap |= 1 << (diff - 1)
            }
        }
        return bitmap
    }

    private enum ReceivedSequenceResult {
        case new
        case duplicate
        case rejected
    }

    private func recordReceivedSequence(_ seq: UInt32) -> ReceivedSequenceResult {
        if !hasReceivedFirstPacket {
            hasReceivedFirstPacket = true
            highestContiguousReceived = seq
            return .new
        }

        let diff = Int32(bitPattern: seq &- highestContiguousReceived)

        if diff <= 0 {
            // Already received or old — ignore
            return .duplicate
        }

        if diff == 1 {
            highestContiguousReceived = seq
            // Advance past any buffered contiguous sequences
            while receivedBeyondContiguous.remove(highestContiguousReceived &+ 1) != nil {
                highestContiguousReceived &+= 1
            }
        } else {
            let maximumGap = UInt32(
                maxFragmentCount(routeToHandshake: false) + maxPendingDeliveryMessages
            )
            guard UInt32(diff) <= maximumGap else {
                close(
                    with: LoomConnectionFailure(
                        reason: .other,
                        detail: "Reliable UDP receive sequence exceeded the bounded reordering window."
                    )
                )
                return .rejected
            }
            guard receivedBeyondContiguous.insert(seq).inserted else {
                return .duplicate
            }
        }
        return .new
    }

    private func processIncomingAck(ackSequence: UInt32, ackBitmap: UInt32) {
        // Remove acked packets
        _ = removePendingAck(sequence: ackSequence)

        // Process bitmap — bit N means (ackSequence + N + 1) is also acked
        for bit in 0..<32 {
            if ackBitmap & (1 << bit) != 0 {
                let ackedSeq = ackSequence &+ UInt32(bit) &+ 1
                if let pending = removePendingAck(sequence: ackedSeq) {
                    updateRTT(sample: CFAbsoluteTimeGetCurrent() - pending.sentAt)
                }
            }
        }

        // Also ack everything up to ackSequence
        let toRemove = pendingAcks.keys.filter { key in
            let diff = Int32(bitPattern: ackSequence &- key)
            return diff >= 0
        }
        for key in toRemove {
            if let pending = removePendingAck(sequence: key) {
                updateRTT(sample: CFAbsoluteTimeGetCurrent() - pending.sentAt)
            }
        }
    }

    // MARK: - RTT Estimation

    private func updateRTT(sample: Double) {
        guard sample > 0 else { return }
        // EWMA: smoothedRTT = 0.875 * smoothedRTT + 0.125 * sample
        smoothedRTT = 0.875 * smoothedRTT + 0.125 * sample
        rttVariance = 0.75 * rttVariance + 0.25 * abs(sample - smoothedRTT)
        rto = max(0.1, smoothedRTT + 4 * rttVariance)
    }

    // MARK: - Pending Packet Tracking

    private struct PendingPacket {
        let packet: Data
        let firstSentAt: CFAbsoluteTime
        var sentAt: CFAbsoluteTime
        var retryCount: Int
        var hasLoggedTimeoutDeferral: Bool
    }

    private func trackPending(seq: UInt32, packet: Data) throws {
        guard pendingAcks[seq] == nil,
              pendingAcks.count < maxPendingReliablePackets,
              packet.count <= maxPendingReliableBytes - pendingAckByteCount else {
            close(
                with: LoomConnectionFailure(
                    reason: .other,
                    detail: "Reliable UDP outbound acknowledgement window exceeded its capacity limit."
                )
            )
            throw LoomError.protocolError(
                "Reliable UDP outbound acknowledgement window exceeded its capacity limit."
            )
        }
        let now = CFAbsoluteTimeGetCurrent()
        pendingAcks[seq] = PendingPacket(
            packet: packet,
            firstSentAt: now,
            sentAt: now,
            retryCount: 0,
            hasLoggedTimeoutDeferral: false
        )
        pendingAckByteCount += packet.count
    }

    private func removePendingAck(sequence: UInt32) -> PendingPacket? {
        guard let pending = pendingAcks.removeValue(forKey: sequence) else { return nil }
        pendingAckByteCount = max(0, pendingAckByteCount - pending.packet.count)
        return pending
    }

    // MARK: - Retry Timer

    private func startRetryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.retryExpiredPackets()
            }
        }
        timer.resume()
        retryTimer = timer
    }

    private func retryExpiredPackets() {
        let now = CFAbsoluteTimeGetCurrent()
        var failed = false

        if needsAck {
            sendDedicatedAckIfNeeded(now: now)
        }

        for (seq, var pending) in pendingAcks {
            if now - pending.sentAt >= rto {
                let packetAge = now - pending.firstSentAt
                let lastInboundPacketAge = lastInboundPacketAt.map { now - $0 }
                if Self.shouldFailPendingReliablePacket(
                    retryCount: pending.retryCount,
                    maxRetries: maxRetries,
                    packetAge: packetAge,
                    lastInboundPacketAge: lastInboundPacketAge,
                    recentInboundGrace: recentInboundTimeoutGrace,
                    maximumPacketLifetime: absolutePendingAckTimeout
                ) {
                    terminalFailure = LoomConnectionFailure(
                        reason: .timedOut,
                        detail: "Reliable UDP transport timed out awaiting acknowledgement."
                    )
                    failed = true
                    break
                }

                if pending.retryCount >= maxRetries,
                   !pending.hasLoggedTimeoutDeferral {
                    let inboundAgeMs = lastInboundPacketAge.map { Int(($0 * 1000).rounded()) } ?? -1
                    let packetAgeMs = Int((packetAge * 1000).rounded())
                    LoomLogger.transport(
                        "Deferring reliable UDP timeout for seq \(seq) packetAgeMs=\(packetAgeMs) " +
                            "lastInboundAgeMs=\(inboundAgeMs)"
                    )
                    pending.hasLoggedTimeoutDeferral = true
                }

                pending.retryCount += 1
                pending.sentAt = now

                // Update ack fields in the retransmitted packet
                var retransmitPacket = pending.packet
                let ackSeq = currentAckSequence()
                let ackBmp = currentAckBitmap()
                retransmitPacket.withUnsafeMutableBytes { buf in
                    buf.storeBytes(of: ackSeq.littleEndian, toByteOffset: 12, as: UInt32.self)
                    buf.storeBytes(of: ackBmp.littleEndian, toByteOffset: 16, as: UInt32.self)
                }

                pendingAcks[seq] = pending
                Task { [connection] in
                    try? await connection.send(retransmitPacket)
                }
            }
        }

        if failed {
            close(with: terminalFailure)
        }

        pruneFragmentAssemblies(now: now)
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let data = try await self.receiveRawDatagram()
                    await self.handleIncomingPacket(data)
                } catch {
                    if !Task.isCancelled {
                        let failure = (error as? LoomConnectionFailure) ?? LoomConnectionFailure.classify(error)
                        await self.close(with: failure)
                    }
                    break
                }
            }
        }
    }

    private func handleIncomingPacket(_ data: Data) {
        guard !isClosed else { return }
        guard let header = LoomReliablePacketHeader.deserialize(from: data) else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        lastInboundPacketAt = now

        // Process piggyback acks
        if hasReceivedFirstPacket || header.flags.contains(.ackOnly) {
            processIncomingAck(ackSequence: header.ackSequence, ackBitmap: header.ackBitmap)
        }

        // Pure ack — no payload to deliver
        if header.flags.contains(.ackOnly) {
            return
        }

        // Validate payload before recording the sequence.  A truncated
        // packet must NOT advance ACK state — the sender would stop
        // retransmitting while the ordered-delivery buffer stalls.
        let payloadStart = loomReliableHeaderSize
        let payloadEnd = payloadStart + Int(header.payloadLength)
        guard data.count >= payloadEnd else { return }
        let payload = Data(data[payloadStart..<payloadEnd])

        // Unreliable packets bypass sequence tracking and ordered delivery.
        guard header.flags.contains(.reliable) else {
            // Unauthenticated peers have no valid unreliable lane. Do not let
            // pre-handshake traffic consume the authenticated session budget.
            guard !routesReliablePacketsToHandshake else { return }
            if payload.first == LoomSessionTrafficClass.priorityInput.rawValue {
                deliverUnreliable(
                    payload,
                    to: priorityUnreliableDeliveryBuffer,
                    lane: "priority unreliable"
                )
            } else {
                deliverUnreliable(
                    payload,
                    to: unreliableDeliveryBuffer,
                    lane: "unreliable"
                )
            }
            return
        }

        if routesReliablePacketsToHandshake {
            guard header.flags.contains(.hello) else {
                return
            }
            if header.flags.contains(.fragment) {
                guard validateFragmentHeader(header, routeToHandshake: true) else { return }
            }

            guard recordAndAcknowledgeNewSequence(header.sequence, now: now) else { return }
            if header.flags.contains(.fragment) {
                handleFragment(header: header, payload: payload, routeToHandshake: true)
            } else {
                _ = deliver(
                    payload,
                    to: handshakeDeliveryBuffer,
                    lane: "handshake"
                )
            }
            return
        }

        if header.flags.contains(.hello) {
            close(
                with: LoomConnectionFailure(
                    reason: .other,
                    detail: "Reliable UDP received a handshake packet after authentication completed."
                )
            )
            return
        }

        // Record this sequence for our outgoing acks
        if header.flags.contains(.fragment) {
            guard validateFragmentHeader(header, routeToHandshake: false) else { return }
        }
        guard recordAndAcknowledgeNewSequence(header.sequence, now: now) else { return }
        if header.flags.contains(.fragment) {
            handleFragment(header: header, payload: payload, routeToHandshake: false)
        } else {
            bufferForOrderedDelivery(
                sequence: header.sequence,
                sequenceSpan: 1,
                payload: payload
            )
        }
    }

    private func recordAndAcknowledgeNewSequence(
        _ sequence: UInt32,
        now: CFAbsoluteTime
    ) -> Bool {
        let result = recordReceivedSequence(sequence)
        if case .rejected = result {
            return false
        }
        needsAck = true
        if Self.shouldSendImmediateReliableAck(
            lastAckSentAt: lastDedicatedAckSentAt,
            now: now,
            idleThreshold: immediateAckIdleThreshold
        ) {
            sendDedicatedAckIfNeeded(now: now)
        } else {
            scheduleAckIfNeeded()
        }
        if case .new = result {
            return true
        }
        return false
    }

    private func scheduleAckIfNeeded() {
        guard ackTask == nil || ackTask?.isCancelled == true else { return }
        ackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let self, !Task.isCancelled else { return }
            await self.sendScheduledAckIfNeeded()
        }
    }

    private func sendScheduledAckIfNeeded() {
        ackTask = nil
        sendDedicatedAckIfNeeded()
    }

    private func sendDedicatedAckIfNeeded(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        ackTask?.cancel()
        ackTask = nil
        guard needsAck else { return }
        needsAck = false
        lastDedicatedAckSentAt = now
        let header = LoomReliablePacketHeader(
            flags: .ackOnly,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap()
        )
        let packet = header.serialize()
        Task { [connection] in
            try? await connection.send(packet)
        }
    }

    package nonisolated static func shouldSendImmediateReliableAck(
        lastAckSentAt: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        idleThreshold: CFAbsoluteTime
    ) -> Bool {
        guard let lastAckSentAt else { return true }
        return now - lastAckSentAt >= idleThreshold
    }

    package nonisolated static func shouldFailPendingReliablePacket(
        retryCount: Int,
        maxRetries: Int,
        packetAge: CFAbsoluteTime,
        lastInboundPacketAge: CFAbsoluteTime?,
        recentInboundGrace: CFAbsoluteTime,
        maximumPacketLifetime: CFAbsoluteTime
    ) -> Bool {
        guard retryCount >= maxRetries else { return false }
        if packetAge >= maximumPacketLifetime {
            return true
        }
        guard let lastInboundPacketAge else {
            return true
        }
        return lastInboundPacketAge >= recentInboundGrace
    }

    // MARK: - Fragment Reassembly

    private struct FragmentKey: Hashable {
        let streamID: UInt16
        let firstSequence: UInt32
    }

    private struct FragmentAssembly {
        let fragmentCount: UInt16
        let routeToHandshake: Bool
        var fragments: [UInt16: Data]
        let createdAt: CFAbsoluteTime

        var isComplete: Bool { fragments.count == Int(fragmentCount) }
        var totalBytes: Int {
            fragments.values.reduce(0) { $0 + $1.count }
        }

        func reassemble() -> Data {
            var result = Data()
            for i in 0..<fragmentCount {
                if let chunk = fragments[i] {
                    result.append(chunk)
                }
            }
            return result
        }
    }

    private func handleFragment(
        header: LoomReliablePacketHeader,
        payload: Data,
        routeToHandshake: Bool
    ) {
        let firstSeq = header.sequence &- UInt32(header.fragmentIndex)
        let key = FragmentKey(streamID: header.streamID, firstSequence: firstSeq)

        if fragments[key] == nil {
            pruneFragmentAssemblies(now: CFAbsoluteTimeGetCurrent())
            guard !isClosed else { return }
            guard fragments.count < maxPendingFragmentAssemblies else {
                closeForIncomingOverflow("fragment assembly count")
                return
            }
        }

        var assembly = fragments[key] ?? FragmentAssembly(
            fragmentCount: header.fragmentCount,
            routeToHandshake: routeToHandshake,
            fragments: [:],
            createdAt: CFAbsoluteTimeGetCurrent()
        )
        guard assembly.fragmentCount == header.fragmentCount,
              assembly.routeToHandshake == routeToHandshake else {
            if let discarded = fragments.removeValue(forKey: key) {
                releaseFragmentAssembly(discarded)
            }
            close(
                with: LoomConnectionFailure(
                    reason: .other,
                    detail: "Reliable UDP fragment metadata changed within one assembly."
                )
            )
            return
        }

        guard assembly.fragments[header.fragmentIndex] == nil else {
            return
        }
        guard pendingFragmentCount < maxPendingFragments,
              payload.count <= maxPendingFragmentBytes - pendingFragmentByteCount,
              fragmentBudget.reserve(
                  bytes: payload.count,
                  payloadCount: fragments[key] == nil ? 1 : 0,
                  startsNewBatch: fragments[key] == nil
              ) else {
            closeForIncomingOverflow("fragment storage")
            return
        }

        assembly.fragments[header.fragmentIndex] = payload
        pendingFragmentCount += 1
        pendingFragmentByteCount += payload.count
        if assembly.isComplete {
            fragments.removeValue(forKey: key)
            let reassembled = assembly.reassemble()
            releaseFragmentAssembly(assembly)
            if assembly.routeToHandshake {
                _ = deliver(
                    reassembled,
                    to: handshakeDeliveryBuffer,
                    lane: "handshake"
                )
            } else {
                bufferForOrderedDelivery(
                    sequence: firstSeq,
                    sequenceSpan: UInt32(header.fragmentCount),
                    payload: reassembled
                )
            }
        } else {
            fragments[key] = assembly
        }
    }

    private func maxFragmentCount(routeToHandshake: Bool) -> Int {
        let byteLimit = routeToHandshake
            ? LoomMessageLimits.maxHelloFrameBytes
            : LoomMessageLimits.maxFrameBytes
        return max(1, (byteLimit + loomReliableMaxFragmentPayload - 1) / loomReliableMaxFragmentPayload)
    }

    private func validateFragmentHeader(
        _ header: LoomReliablePacketHeader,
        routeToHandshake: Bool
    ) -> Bool {
        guard header.fragmentCount > 0,
              header.fragmentIndex < header.fragmentCount,
              Int(header.fragmentCount) <= maxFragmentCount(routeToHandshake: routeToHandshake) else {
            close(
                with: LoomConnectionFailure(
                    reason: .other,
                    detail: "Reliable UDP received invalid fragment metadata."
                )
            )
            return false
        }
        return true
    }

    private func pruneFragmentAssemblies(now: CFAbsoluteTime) {
        guard fragments.values.contains(where: {
            now - $0.createdAt > fragmentPruneInterval
        }) else {
            return
        }
        close(
            with: LoomConnectionFailure(
                reason: .timedOut,
                detail: "Reliable UDP fragment reassembly timed out."
            )
        )
    }

    private func releaseFragmentAssembly(_ assembly: FragmentAssembly) {
        let fragmentCount = assembly.fragments.count
        guard fragmentCount > 0 else { return }
        pendingFragmentCount = max(0, pendingFragmentCount - fragmentCount)
        pendingFragmentByteCount = max(0, pendingFragmentByteCount - assembly.totalBytes)
        fragmentBudget.release(
            bytes: assembly.totalBytes,
            payloadCount: 1,
            batchCount: 1
        )
    }

    // MARK: - Ordered Delivery

    private struct PendingMessage {
        let payload: Data
        let sequenceSpan: UInt32
    }

    private func bufferForOrderedDelivery(
        sequence: UInt32,
        sequenceSpan: UInt32,
        payload: Data
    ) {
        if !hasSetInitialDeliverySequence {
            hasSetInitialDeliverySequence = true
            nextDeliverySequence = sequence
        }

        // Discard messages already delivered (duplicate/retransmit)
        let diff = Int32(bitPattern: sequence &- nextDeliverySequence)
        guard diff >= 0 else { return }
        guard pendingDelivery[sequence] == nil else { return }

        let maximumSequenceGap = UInt32(
            maxFragmentCount(routeToHandshake: false) + maxPendingDeliveryMessages
        )
        guard UInt32(diff) <= maximumSequenceGap,
              pendingDelivery.count < maxPendingDeliveryMessages,
              payload.count <= maxPendingDeliveryBytes,
              orderedDeliveryBudget.reserve(
                  bytes: payload.count,
                  payloadCount: 1,
                  startsNewBatch: true
              ) else {
            closeForIncomingOverflow("ordered delivery window")
            return
        }

        pendingDelivery[sequence] = PendingMessage(
            payload: payload,
            sequenceSpan: sequenceSpan
        )
        flushDeliveryBuffer()
    }

    private func flushDeliveryBuffer() {
        while let message = pendingDelivery.removeValue(forKey: nextDeliverySequence) {
            let result = deliveryBuffer.yield(message.payload, alreadyRetained: true)
            guard case .accepted = result else {
                orderedDeliveryBudget.release(
                    bytes: message.payload.count,
                    payloadCount: 1,
                    batchCount: 1
                )
                closeForIncomingOverflow("ordered delivery queue")
                return
            }
            nextDeliverySequence &+= message.sequenceSpan
        }
    }

    @discardableResult
    private func deliver(
        _ payload: Data,
        to buffer: LoomBoundedIncomingDataBuffer,
        lane: String
    ) -> Bool {
        guard case .accepted = buffer.yield(payload) else {
            closeForIncomingOverflow("\(lane) delivery queue")
            return false
        }
        return true
    }

    private func deliverUnreliable(
        _ payload: Data,
        to buffer: LoomBoundedIncomingDataBuffer,
        lane: String
    ) {
        let yieldResult = buffer.yieldReplacingOldest(payload)
        if yieldResult.replacedPayloadCount > 0 {
            noteUnreliableDeliveryDrops(
                lane: lane,
                payloadBytes: payload.count,
                count: yieldResult.replacedPayloadCount
            )
        }
        switch yieldResult.result {
        case .accepted:
            return
        case .overflow:
            noteUnreliableDeliveryDrops(lane: lane, payloadBytes: payload.count, count: 1)
        case .invalid, .terminated:
            return
        }
    }

    private func noteUnreliableDeliveryDrops(lane: String, payloadBytes: Int, count: Int) {
        droppedUnreliableDeliveryPayloadCount &+= UInt64(count)
        let now = CFAbsoluteTimeGetCurrent()
        if droppedUnreliableDeliveryPayloadCount != 1,
           let lastUnreliableDeliveryDropLogAt,
           now - lastUnreliableDeliveryDropLogAt < 1.0 {
            return
        }
        lastUnreliableDeliveryDropLogAt = now
        LoomLogger.transport(
            "Dropped saturated Reliable UDP \(lane) payload without closing the session " +
                "payloadBytes=\(payloadBytes) totalDrops=\(droppedUnreliableDeliveryPayloadCount)"
        )
    }

    private func closeForIncomingOverflow(_ storage: String) {
        close(
            with: LoomConnectionFailure(
                reason: .other,
                detail: "Reliable UDP \(storage) exceeded its retained-capacity limit."
            )
        )
    }

    private func discardRetainedIncomingState() {
        for assembly in fragments.values {
            releaseFragmentAssembly(assembly)
        }
        fragments.removeAll(keepingCapacity: false)
        pendingFragmentCount = 0
        pendingFragmentByteCount = 0

        for message in pendingDelivery.values {
            orderedDeliveryBudget.release(
                bytes: message.payload.count,
                payloadCount: 1,
                batchCount: 1
            )
        }
        pendingDelivery.removeAll(keepingCapacity: false)
        receivedBeyondContiguous.removeAll(keepingCapacity: false)
    }

    // MARK: - Raw I/O

    private func sendRaw(_ data: Data) async throws {
        do {
            try await connection.send(data)
        } catch {
            throw LoomError.connectionFailed(LoomConnectionFailure.classify(error))
        }
    }

    private func receiveRawDatagram() async throws -> Data {
        do {
            guard let data = try await connection.receive(maximumBytes: 65_535) else {
                throw LoomError.connectionFailed(
                    LoomConnectionFailure(reason: .closed, detail: "UDP connection closed.")
                )
            }
            return data
        } catch let error as LoomError {
            throw error
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
