//
//  LoomSessionTransport.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation
import Dispatch

package enum LoomSessionReceiveSemantics: Sendable {
    case singleLane
    case independentReliableAndUnreliable
}

package enum LoomSessionTransportObservation: Sendable {
    case path(LoomNetworkPath)
    case failed(String)
    case cancelled
}

/// Abstraction over the framing/delivery layer beneath an authenticated Loom session.
///
/// `LoomFramedConnection` (TCP), `LoomReliableChannel` (UDP), and QUIC transports conform,
/// allowing `LoomAuthenticatedSession` to be transport-agnostic.
package protocol LoomSessionTransport: Sendable {
    /// Describes whether the transport exposes one shared inbound message lane
    /// or genuinely separate reliable and unreliable receive lanes.
    var receiveSemantics: LoomSessionReceiveSemantics { get }

    /// Start the underlying connection and block until it is ready for I/O.
    ///
    /// Starts the backend connection and waits for it to become usable.
    func startAndAwaitReady(queue: DispatchQueue) async throws

    /// Send a complete message reliably (ordered, retransmitted if needed).
    func sendMessage(_ data: Data) async throws

    /// Receive the next complete reliable message.
    func receiveMessage(maxBytes: Int) async throws -> Data

    /// Receive a bounded batch of reliable messages when the transport can
    /// drain an ordered byte stream without an extra suspension per message.
    func receiveMessageBatch(maxBytes: Int, maximumMessages: Int) async throws -> [Data]

    /// Send a pre-encryption handshake message.
    func sendHandshakeMessage(_ data: Data) async throws

    /// Receive the next pre-encryption handshake message candidate.
    func receiveHandshakeMessage(maxBytes: Int) async throws -> Data

    /// Send a message without reliability guarantees (fire-and-forget, no retransmission).
    func sendUnreliable(_ data: Data) async throws

    /// Enqueue an unreliable message for ordered, non-blocking transmission.
    ///
    /// The method returns after the transport has accepted the payload for send
    /// scheduling. Completion runs later when the backend either accepts or
    /// rejects the underlying send operation.
    func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile,
        options: LoomQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) async

    /// Enqueue an ordered batch of unreliable messages in one transport admission.
    func sendUnreliableQueuedBatch(
        _ items: [LoomQueuedUnreliableBatchItem],
        profile: LoomQueuedUnreliableSendProfile
    ) async

    /// Cancel queued unreliable sends for one profile without disturbing the
    /// queues used by other traffic classes.
    func resetQueuedUnreliableSends(
        profile: LoomQueuedUnreliableSendProfile
    ) async

    /// Consume diagnostics for one queued-unreliable send profile.
    func consumeQueuedUnreliableSendDiagnostics(
        profile: LoomQueuedUnreliableSendProfile
    ) async -> LoomQueuedUnreliableSendDiagnostics?

    /// Receive the next unreliable message.
    func receiveUnreliable(maxBytes: Int) async throws -> Data

    /// Receive a bounded batch of unreliable messages when the transport can
    /// drain a message-preserving lane without an extra suspension per message.
    func receiveUnreliableBatch(maxBytes: Int, maximumMessages: Int) async throws -> [Data]

    /// Prepare the unreliable receive lane before the authenticated session is
    /// advertised as ready. Transports with lazily-created datagram flows use
    /// this to avoid dropping the first media packet after bootstrap.
    func prepareUnreliableReceive(maxBytes: Int) async throws

    /// Receive the next priority unreliable message, when the transport exposes
    /// an independent lane.
    func receivePriorityUnreliable(maxBytes: Int) async throws -> Data

    /// Cancel any pending queued unreliable sends that have not yet been
    /// submitted to the underlying connection.
    func cancelPendingUnreliableSends() async

    /// Close transport-owned tasks and queues during authenticated-session teardown.
    func closeTransport() async

    /// Closes transport after an ordered reliable write crosses its deadline. Shared backends may
    /// need a wider socket cut because allowing one late write is less safe than collateral closure.
    func hardCloseTransport() async

    /// Installs a transport-owned observation hook for path and lifecycle updates.
    func setObservationHandler(
        _ handler: (@Sendable (LoomSessionTransportObservation) -> Void)?
    ) async
}

extension LoomSessionTransport {
    package func receiveMessageBatch(
        maxBytes: Int,
        maximumMessages: Int
    ) async throws -> [Data] {
        guard maximumMessages > 0 else {
            throw LoomError.protocolError("Invalid reliable receive batch size.")
        }
        return [try await receiveMessage(maxBytes: maxBytes)]
    }

    package func sendUnreliableQueuedBatch(
        _ items: [LoomQueuedUnreliableBatchItem],
        profile: LoomQueuedUnreliableSendProfile
    ) async {
        for item in items {
            await sendUnreliableQueued(
                item.data,
                profile: profile,
                options: item.options,
                onComplete: item.onComplete
            )
        }
    }

    package func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) async {
        await sendUnreliableQueued(
            data,
            profile: profile,
            options: .none,
            onComplete: onComplete
        )
    }

    package func closeTransport() async {
        await cancelPendingUnreliableSends()
    }

    package func hardCloseTransport() async {
        await closeTransport()
    }

    package func consumeQueuedUnreliableSendDiagnostics(
        profile: LoomQueuedUnreliableSendProfile
    ) async -> LoomQueuedUnreliableSendDiagnostics? {
        nil
    }

    package func prepareUnreliableReceive(maxBytes: Int) async throws {}

    package func receiveUnreliableBatch(
        maxBytes: Int,
        maximumMessages: Int
    ) async throws -> [Data] {
        guard maximumMessages > 0 else {
            throw LoomError.protocolError("Invalid unreliable receive batch size.")
        }
        return [try await receiveUnreliable(maxBytes: maxBytes)]
    }

    package func setObservationHandler(
        _ handler: (@Sendable (LoomSessionTransportObservation) -> Void)?
    ) async {}
}
