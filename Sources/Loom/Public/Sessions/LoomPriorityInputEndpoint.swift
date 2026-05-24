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

    private let securityContext: LoomSessionSecurityContext
    private let sendFrame:
        @Sendable (Data, LoomQueuedUnreliableSendProfile, @escaping @Sendable (Error?) -> Void) async -> Void
    private let receiveFrame: @Sendable (Int) async throws -> Data

    package init(
        securityContext: LoomSessionSecurityContext,
        sendFrame:
            @escaping @Sendable (Data, LoomQueuedUnreliableSendProfile, @escaping @Sendable (Error?) -> Void) async -> Void,
        receiveFrame: @escaping @Sendable (Int) async throws -> Data
    ) {
        self.securityContext = securityContext
        self.sendFrame = sendFrame
        self.receiveFrame = receiveFrame
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
        let securityContext = securityContext
        let receiveFrame = receiveFrame
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .high) {
                while !Task.isCancelled {
                    do {
                        let frame = try await receiveFrame(maxBytes)
                        let payload = try Self.decode(
                            frame,
                            securityContext: securityContext
                        )
                        continuation.yield(payload)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        securityContext: LoomSessionSecurityContext
    ) throws -> Data {
        guard frame.first == LoomSessionTrafficClass.priorityInput.rawValue else {
            throw LoomError.protocolError("Received non-priority payload on priority input lane.")
        }
        return try securityContext.open(
            Data(frame.dropFirst()),
            trafficClass: .priorityInput
        )
    }
}
