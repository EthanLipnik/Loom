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
    case path(LoomSessionNetworkPathSnapshot)
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
    /// Sets the `stateUpdateHandler` **before** calling `NWConnection.start(queue:)`
    /// so that no state transitions are lost — per Apple's Network.framework documentation.
    func startAndAwaitReady(queue: DispatchQueue) async throws

    /// Send a complete message reliably (ordered, retransmitted if needed).
    func sendMessage(_ data: Data) async throws

    /// Receive the next complete reliable message.
    func receiveMessage(maxBytes: Int) async throws -> Data

    /// Send a pre-encryption handshake message.
    func sendHandshakeMessage(_ data: Data) async throws

    /// Receive the next pre-encryption handshake message candidate.
    func receiveHandshakeMessage(maxBytes: Int) async throws -> Data

    /// Send a message without reliability guarantees (fire-and-forget, no retransmission).
    func sendUnreliable(_ data: Data) async throws

    /// Enqueue an unreliable message for ordered, non-blocking transmission.
    ///
    /// The method returns after the transport has accepted the payload for send
    /// scheduling. Completion runs later when Network.framework either accepts
    /// or rejects the underlying send operation.
    func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) async

    /// Cancel queued unreliable sends for one profile without disturbing the
    /// queues used by other traffic classes.
    func resetQueuedUnreliableSends(
        profile: LoomQueuedUnreliableSendProfile
    ) async

    /// Receive the next unreliable message.
    func receiveUnreliable(maxBytes: Int) async throws -> Data

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

    /// Installs a transport-owned observation hook for path and lifecycle updates.
    func setObservationHandler(
        _ handler: (@Sendable (LoomSessionTransportObservation) -> Void)?
    ) async
}

extension LoomSessionTransport {
    package func closeTransport() async {
        await cancelPendingUnreliableSends()
    }

    package func prepareUnreliableReceive(maxBytes: Int) async throws {}

    package func setObservationHandler(
        _ handler: (@Sendable (LoomSessionTransportObservation) -> Void)?
    ) async {}
}
