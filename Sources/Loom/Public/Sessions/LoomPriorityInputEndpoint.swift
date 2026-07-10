//
//  LoomPriorityInputEndpoint.swift
//  Loom
//
//  Created by Ethan Lipnik on 5/15/26.
//

import Foundation

/// Direct local datagram input lane for latency-sensitive application input.
///
/// Priority input payloads are encrypted with their own traffic class and are
/// delivered outside the normal multiplexed stream receive actor. Realtime
/// sends keep only the newest pending payload, sequenced realtime sends preserve
/// a short FIFO window, and protected sends preserve a shallow independent queue
/// so applications can layer acknowledgements and fallback behavior on top.
public final class LoomPriorityInputEndpoint: @unchecked Sendable {
    public static let maximumPayloadBytes = 1 * 1024 * 1024
    package static let maximumBufferedIncomingBytes = 4 * 1024 * 1024
    package static let maximumBufferedIncomingPayloads = 256

    private static let encryptedFrameOverheadBytes = 1 + 12 + 16

    private let securityContext: LoomSessionSecurityContext
    private let sendFrame:
        @Sendable (Data, LoomQueuedUnreliableSendProfile, @escaping @Sendable (Error?) -> Void) async -> Void
    private let receiveFrame: @Sendable (Int) async throws -> Data
    private let retainedCapacityBudget: LoomIncomingRetainedCapacityBudget?
    private let maximumBufferedIncomingBytes: Int
    private let maximumBufferedIncomingPayloads: Int

    package init(
        securityContext: LoomSessionSecurityContext,
        sendFrame:
            @escaping @Sendable (Data, LoomQueuedUnreliableSendProfile, @escaping @Sendable (Error?) -> Void) async -> Void,
        receiveFrame: @escaping @Sendable (Int) async throws -> Data,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        maximumBufferedIncomingBytes: Int = LoomPriorityInputEndpoint.maximumBufferedIncomingBytes,
        maximumBufferedIncomingPayloads: Int = LoomPriorityInputEndpoint.maximumBufferedIncomingPayloads
    ) {
        self.securityContext = securityContext
        self.sendFrame = sendFrame
        self.receiveFrame = receiveFrame
        self.retainedCapacityBudget = retainedCapacityBudget
        self.maximumBufferedIncomingBytes = max(1, maximumBufferedIncomingBytes)
        self.maximumBufferedIncomingPayloads = max(1, maximumBufferedIncomingPayloads)
    }

    /// Send coalescible realtime input. If the transport is backpressured, the
    /// newest queued realtime input replaces older queued realtime input.
    public func sendRealtime(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        send(payload, profile: .priorityInputRealtime, onComplete: onComplete)
    }

    /// Send realtime input that should preserve short-term motion continuity.
    /// If the transport is backpressured, older queued samples are dropped only
    /// after a bounded FIFO window fills.
    public func sendRealtimeSequenced(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        send(payload, profile: .priorityInputRealtimeSequenced, onComplete: onComplete)
    }

    /// Send compact continuous input batches that should preserve sample
    /// continuity without replacing queued packets.
    public func sendContinuous(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        send(payload, profile: .priorityInputContinuous, onComplete: onComplete)
    }

    /// Send protected input on the priority lane. The application should pair
    /// this with an acknowledgement and reliable fallback for exactly-once
    /// actions such as clicks and key events.
    public func sendProtected(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        send(payload, profile: .priorityInputProtected, onComplete: onComplete)
    }

    /// Creates a stream of decrypted priority input payloads.
    public func makeIncomingPayloadStream(
        maxBytes: Int = LoomPriorityInputEndpoint.maximumPayloadBytes
    ) -> AsyncStream<Data> {
        guard maxBytes > 0 else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        let maximumDecodedPayloadBytes = min(maxBytes, Self.maximumPayloadBytes)
        let maximumEncryptedFrameBytes = maximumDecodedPayloadBytes + Self.encryptedFrameOverheadBytes
        let securityContext = securityContext
        let receiveFrame = receiveFrame
        let buffer = LoomPriorityIncomingPayloadBuffer(
            maximumBufferedBytes: maximumBufferedIncomingBytes,
            maximumBufferedItems: maximumBufferedIncomingPayloads,
            retainedCapacityBudget: retainedCapacityBudget
        )
        let stream = buffer.makeStream()
        let task = Task.detached(priority: .high) { [weak buffer] in
            while !Task.isCancelled {
                do {
                    let frame = try await receiveFrame(maximumEncryptedFrameBytes)
                    let payload = try Self.decode(
                        frame,
                        maximumPayloadBytes: maximumDecodedPayloadBytes,
                        securityContext: securityContext
                    )
                    guard let buffer else { return }
                    switch buffer.yield(payload) {
                    case .accepted:
                        continue
                    case .invalid, .overflow:
                        buffer.abort()
                        return
                    case .terminated:
                        return
                    }
                } catch {
                    buffer?.finish()
                    return
                }
            }
            buffer?.finish()
        }
        buffer.installProducer(task)
        return stream
    }

    private func send(
        _ payload: Data,
        profile: LoomQueuedUnreliableSendProfile,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        do {
            let frame = try Self.encode(payload, securityContext: securityContext)
            let sendFrame = sendFrame
            Task.detached(priority: .high) {
                await sendFrame(frame, profile, onComplete)
            }
        } catch {
            onComplete(error)
        }
    }

    private static func encode(
        _ payload: Data,
        securityContext: LoomSessionSecurityContext
    ) throws -> Data {
        guard !payload.isEmpty else {
            throw LoomError.protocolError("Priority input payloads must not be empty.")
        }
        guard payload.count <= maximumPayloadBytes else {
            throw LoomError.protocolError("Priority input payload exceeds \(maximumPayloadBytes) bytes.")
        }
        let encryptedPayload = try securityContext.seal(
            payload,
            trafficClass: .priorityInput
        )
        var frame = Data(capacity: encryptedPayload.count + 1)
        frame.append(LoomSessionTrafficClass.priorityInput.rawValue)
        frame.append(encryptedPayload)
        return frame
    }

    private static func decode(
        _ frame: Data,
        maximumPayloadBytes: Int,
        securityContext: LoomSessionSecurityContext
    ) throws -> Data {
        guard frame.first == LoomSessionTrafficClass.priorityInput.rawValue else {
            throw LoomError.protocolError("Received non-priority payload on priority input lane.")
        }
        let payload = try securityContext.open(
            Data(frame.dropFirst()),
            trafficClass: .priorityInput
        )
        guard !payload.isEmpty else {
            throw LoomError.protocolError("Received an empty priority input payload.")
        }
        guard payload.count <= maximumPayloadBytes else {
            throw LoomError.protocolError(
                "Priority input payload exceeds \(maximumPayloadBytes) bytes."
            )
        }
        return payload
    }
}
