//
//  LoomReliableChannel.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation
import Network

/// Reliable datagram transport for Loom sessions over UDP.
///
/// Provides ordered, reliable delivery of arbitrary-size messages on top of an
/// `NWConnection` configured for UDP. Implements selective-ACK with piggyback
/// acknowledgments, automatic retransmission, and transparent fragmentation
/// for messages exceeding a single datagram.
package actor LoomReliableChannel: LoomSessionTransport {
    private let connection: NWConnection
    private let queuedUnreliableSender: LoomOrderedUnreliableSendQueue
    package let receiveSemantics: LoomSessionReceiveSemantics = .independentReliableAndUnreliable

    // MARK: - Send State

    private var nextSequence: UInt32 = 0
    private var pendingAcks: [UInt32: PendingPacket] = [:]
    private var retryTimer: DispatchSourceTimer?
    private let sendQueue = DispatchQueue(label: "loom.reliable.send", qos: .userInteractive)

    // MARK: - Receive State

    private var highestContiguousReceived: UInt32 = 0
    private var receivedBeyondContiguous: Set<UInt32> = []
    private var hasReceivedFirstPacket = false
    private var fragments: [FragmentKey: FragmentAssembly] = [:]
    private var needsAck = false
    private var lastInboundPacketAt: CFAbsoluteTime?
    private var lastDedicatedAckSentAt: CFAbsoluteTime?

    // MARK: - Delivery

    private var deliveryContinuation: AsyncStream<Data>.Continuation?
    private let deliveryStream: AsyncStream<Data>

    private var unreliableDeliveryContinuation: AsyncStream<Data>.Continuation?
    private let unreliableDeliveryStream: AsyncStream<Data>

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
    private let recentInboundTimeoutGrace: Double = 5.0
    private let absolutePendingAckTimeout: Double = 15.0

    // MARK: - Lifecycle

    private var receiveTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var isClosed = false
    private var terminalFailure: LoomConnectionFailure?

    package init(connection: NWConnection) {
        self.connection = connection
        queuedUnreliableSender = LoomOrderedUnreliableSendQueue(
            connection: connection,
            queue: sendQueue
        )
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        deliveryStream = stream
        deliveryContinuation = continuation
        let (uStream, uContinuation) = AsyncStream.makeStream(of: Data.self)
        unreliableDeliveryStream = uStream
        unreliableDeliveryContinuation = uContinuation
    }

    deinit {
        retryTimer?.cancel()
        receiveTask?.cancel()
        ackTask?.cancel()
        deliveryContinuation?.finish()
        unreliableDeliveryContinuation?.finish()
    }

    // MARK: - LoomSessionTransport

    package func startAndAwaitReady(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ReadyContinuationBox(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.complete(.success(()))
                case let .failed(error):
                    box.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                case .cancelled:
                    box.complete(
                        .failure(
                            LoomError.connectionFailed(
                                LoomConnectionFailure(reason: .cancelled, detail: "Connection cancelled.")
                            )
                        )
                    )
                case .waiting(let error):
                    LoomLogger.transport("UDP connection waiting: \(error)")
                    if case .posix(let code) = error,
                       ([.ENETDOWN, .EHOSTUNREACH, .ENETUNREACH] as [POSIXErrorCode]).contains(code) {
                        // Give the interface 2 seconds to come up; if .ready
                        // fires first the box is already consumed and this
                        // completion is a safe no-op.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            box.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                        }
                    }
                default:
                    break
                }
            }
            // Handler is set — now start. All state transitions are captured.
            connection.start(queue: queue)
        }
        startReceiveLoop()
        startRetryTimer()
    }

    package func sendMessage(_ data: Data) async throws {
        guard !isClosed else {
            throw LoomError.protocolError("Reliable channel is closed.")
        }

        let fragmentPayload = loomReliableMaxFragmentPayload
        if data.count <= fragmentPayload {
            let seq = allocateSequence()
            let header = LoomReliablePacketHeader(
                flags: .reliable,
                sequence: seq,
                ackSequence: currentAckSequence(),
                ackBitmap: currentAckBitmap(),
                fragmentIndex: 0,
                fragmentCount: 1,
                payloadLength: UInt16(data.count)
            )
            let packet = header.serialize() + data
            trackPending(seq: seq, packet: packet)
            clearNeedsAck()
            try await sendRaw(packet)
        } else {
            let totalFragments = (data.count + fragmentPayload - 1) / fragmentPayload
            guard totalFragments <= Int(UInt16.max) else {
                throw LoomError.protocolError("Message too large to fragment (\(data.count) bytes).")
            }

            // Send fragments in batches with yields between batches to avoid
            // overwhelming the NWConnection's kernel send buffer. Without
            // backpressure, ~950 fragments (for a 1MB payload) saturate the
            // UDP send buffer and cause the connection to be cancelled.
            let sendBatchSize = 16
            for i in 0..<totalFragments {
                let start = i * fragmentPayload
                let end = min(start + fragmentPayload, data.count)
                let chunk = data[start..<end]
                let seq = allocateSequence()

                let header = LoomReliablePacketHeader(
                    flags: [.reliable, .fragment],
                    sequence: seq,
                    ackSequence: currentAckSequence(),
                    ackBitmap: currentAckBitmap(),
                    fragmentIndex: UInt16(i),
                    fragmentCount: UInt16(totalFragments),
                    payloadLength: UInt16(chunk.count)
                )
                let packet = header.serialize() + chunk
                trackPending(seq: seq, packet: packet)
                clearNeedsAck()
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

    /// Send a message without requiring acknowledgment (fire-and-forget).
    /// Unreliable packets do not consume reliable sequence numbers and are
    /// never retransmitted.
    package func sendUnreliable(_ data: Data) async throws {
        guard !isClosed else { return }

        let header = LoomReliablePacketHeader(
            flags: [],
            sequence: 0,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap(),
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: UInt16(data.count)
        )
        clearNeedsAck()
        try await sendRaw(header.serialize() + data)
    }

    package func sendUnreliableQueued(_ data: Data, onComplete: @escaping @Sendable (Error?) -> Void) async {
        guard !isClosed else {
            onComplete(LoomError.protocolError("Reliable channel is closed."))
            return
        }

        let header = LoomReliablePacketHeader(
            flags: [],
            sequence: 0,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap(),
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: UInt16(data.count)
        )
        clearNeedsAck()
        let packet = header.serialize() + data
        queuedUnreliableSender.enqueue(packet) { error in
            if let error {
                onComplete(LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
            } else {
                onComplete(nil)
            }
        }
    }

    package func receiveUnreliable(maxBytes: Int) async throws -> Data {
        for await message in unreliableDeliveryStream {
            if message.count > maxBytes {
                throw LoomError.protocolError(
                    "Received unreliable message exceeds limit: \(message.count) > \(maxBytes)"
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

    package func cancelPendingUnreliableSends() async {
        queuedUnreliableSender.close()
    }

    package func close(with failure: LoomConnectionFailure? = nil) {
        guard !isClosed else { return }
        isClosed = true
        queuedUnreliableSender.close()
        if let failure {
            terminalFailure = failure
        } else if terminalFailure == nil {
            terminalFailure = LoomConnectionFailure(reason: .cancelled, detail: "Reliable channel cancelled.")
        }
        retryTimer?.cancel()
        receiveTask?.cancel()
        ackTask?.cancel()
        deliveryContinuation?.finish()
        deliveryContinuation = nil
        unreliableDeliveryContinuation?.finish()
        unreliableDeliveryContinuation = nil
        connection.cancel()
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

    private func recordReceivedSequence(_ seq: UInt32) {
        if !hasReceivedFirstPacket {
            hasReceivedFirstPacket = true
            highestContiguousReceived = seq
            return
        }

        let diff = Int32(bitPattern: seq &- highestContiguousReceived)

        if diff <= 0 {
            // Already received or old — ignore
            return
        }

        if diff == 1 {
            highestContiguousReceived = seq
            // Advance past any buffered contiguous sequences
            while receivedBeyondContiguous.remove(highestContiguousReceived &+ 1) != nil {
                highestContiguousReceived &+= 1
            }
        } else {
            receivedBeyondContiguous.insert(seq)
            // Prune entries too far behind
            let pruneThreshold = highestContiguousReceived &+ 64
            receivedBeyondContiguous = receivedBeyondContiguous.filter { s in
                let d = Int32(bitPattern: s &- highestContiguousReceived)
                return d > 0 && s &- highestContiguousReceived <= 64
            }
            _ = pruneThreshold
        }
    }

    private func processIncomingAck(ackSequence: UInt32, ackBitmap: UInt32) {
        // Remove acked packets
        pendingAcks.removeValue(forKey: ackSequence)

        // Process bitmap — bit N means (ackSequence + N + 1) is also acked
        for bit in 0..<32 {
            if ackBitmap & (1 << bit) != 0 {
                let ackedSeq = ackSequence &+ UInt32(bit) &+ 1
                if let pending = pendingAcks.removeValue(forKey: ackedSeq) {
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
            if let pending = pendingAcks.removeValue(forKey: key) {
                updateRTT(sample: CFAbsoluteTimeGetCurrent() - pending.sentAt)
            }
        }
    }

    private func clearNeedsAck() {
        needsAck = false
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

    private func trackPending(seq: UInt32, packet: Data) {
        let now = CFAbsoluteTimeGetCurrent()
        pendingAcks[seq] = PendingPacket(
            packet: packet,
            firstSentAt: now,
            sentAt: now,
            retryCount: 0,
            hasLoggedTimeoutDeferral: false
        )
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
                connection.send(content: retransmitPacket, completion: .idempotent)
            }
        }

        if failed {
            close(with: terminalFailure)
        }

        // Send dedicated ack if peer is waiting
        if needsAck {
            needsAck = false
            let header = LoomReliablePacketHeader(
                flags: .ackOnly,
                ackSequence: currentAckSequence(),
                ackBitmap: currentAckBitmap()
            )
            connection.send(content: header.serialize(), completion: .idempotent)
        }

        // Prune stale fragment assemblies
        for (key, assembly) in fragments {
            if now - assembly.createdAt > fragmentPruneInterval {
                fragments.removeValue(forKey: key)
            }
        }
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
            unreliableDeliveryContinuation?.yield(payload)
            return
        }

        // Record this sequence for our outgoing acks
        recordReceivedSequence(header.sequence)
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

        if header.flags.contains(.fragment) {
            handleFragment(header: header, payload: payload)
        } else {
            bufferForOrderedDelivery(
                sequence: header.sequence,
                sequenceSpan: 1,
                payload: payload
            )
        }
    }

    private func scheduleAckIfNeeded() {
        guard ackTask == nil || ackTask?.isCancelled == true else { return }
        ackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let self, !Task.isCancelled else { return }
            await self.sendDedicatedAckIfNeeded()
        }
    }

    private func sendDedicatedAckIfNeeded(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard needsAck else { return }
        needsAck = false
        lastDedicatedAckSentAt = now
        let header = LoomReliablePacketHeader(
            flags: .ackOnly,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap()
        )
        connection.send(content: header.serialize(), completion: .idempotent)
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
        var fragments: [UInt16: Data]
        let createdAt: CFAbsoluteTime

        var isComplete: Bool { fragments.count == Int(fragmentCount) }

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

    private func handleFragment(header: LoomReliablePacketHeader, payload: Data) {
        let firstSeq = header.sequence &- UInt32(header.fragmentIndex)
        let key = FragmentKey(streamID: header.streamID, firstSequence: firstSeq)

        var assembly = fragments[key] ?? FragmentAssembly(
            fragmentCount: header.fragmentCount,
            fragments: [:],
            createdAt: CFAbsoluteTimeGetCurrent()
        )

        assembly.fragments[header.fragmentIndex] = payload
        if assembly.isComplete {
            fragments.removeValue(forKey: key)
            bufferForOrderedDelivery(
                sequence: firstSeq,
                sequenceSpan: UInt32(header.fragmentCount),
                payload: assembly.reassemble()
            )
        } else {
            fragments[key] = assembly
        }
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

        pendingDelivery[sequence] = PendingMessage(
            payload: payload,
            sequenceSpan: sequenceSpan
        )
        flushDeliveryBuffer()
    }

    private func flushDeliveryBuffer() {
        while let message = pendingDelivery.removeValue(forKey: nextDeliverySequence) {
            deliveryContinuation?.yield(message.payload)
            nextDeliverySequence &+= message.sequenceSpan
        }
    }

    // MARK: - Raw I/O

    private func sendRaw(_ data: Data) async throws {
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

    private func receiveRawDatagram() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
                    return
                }
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(
                        throwing: LoomError.connectionFailed(
                            LoomConnectionFailure(reason: .closed, detail: "UDP connection closed.")
                        )
                    )
                    return
                }
                continuation.resume(
                    throwing: LoomError.protocolError("No data received from UDP connection.")
                )
            }
        }
    }
}

// MARK: - Continuation Safety

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
