//
//  LoomVirtualAppSession.swift
//  LoomHost
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation
import Loom

package actor LoomVirtualAppSession: LoomSessionProtocol {
    package let transportKind: LoomTransportKind
    package let context: LoomAuthenticatedSessionContext?

    private let connectionID: UUID
    private let openHandler: @Sendable (UUID, UInt16, String?) async throws -> Void
    private let sendHandler: @Sendable (UUID, UInt16, Data) async throws -> Void
    private let closeHandler: @Sendable (UUID, UInt16) async throws -> Void
    private let cancelHandler: @Sendable (UUID) async -> Void
    private let hardCutHandler: @Sendable (UUID) async -> Void
    private let reliableSendAdmission = LoomReliableSendAdmission()
    private let stateObservers = LoomAsyncBroadcaster<LoomAuthenticatedSessionState>()
    private let bootstrapProgressObservers = LoomAsyncBroadcaster<LoomAuthenticatedSessionBootstrapProgress>()
    private let incomingStreamObservers = LoomAsyncBroadcaster<LoomMultiplexedStream>()

    private var state: LoomAuthenticatedSessionState = .ready
    private var bootstrapProgress = LoomAuthenticatedSessionBootstrapProgress(phase: .ready)
    private var streams: [UInt16: LoomMultiplexedStream] = [:]
    private var nextOutgoingStreamID: UInt16 = 1

    package init(
        connectionID: UUID,
        transportKind: LoomTransportKind,
        context: LoomAuthenticatedSessionContext?,
        openHandler: @escaping @Sendable (UUID, UInt16, String?) async throws -> Void,
        sendHandler: @escaping @Sendable (UUID, UInt16, Data) async throws -> Void,
        closeHandler: @escaping @Sendable (UUID, UInt16) async throws -> Void,
        cancelHandler: @escaping @Sendable (UUID) async -> Void,
        hardCutHandler: @escaping @Sendable (UUID) async -> Void
    ) {
        self.connectionID = connectionID
        self.transportKind = transportKind
        self.context = context
        self.openHandler = openHandler
        self.sendHandler = sendHandler
        self.closeHandler = closeHandler
        self.cancelHandler = cancelHandler
        self.hardCutHandler = hardCutHandler
    }

    deinit {
        stateObservers.finish()
        bootstrapProgressObservers.finish()
        incomingStreamObservers.finish()
    }

    package nonisolated func makeIncomingStreamObserver() -> AsyncStream<LoomMultiplexedStream> {
        incomingStreamObservers.makeStream()
    }

    package func makeStateObserver() -> AsyncStream<LoomAuthenticatedSessionState> {
        stateObservers.makeStream(initialValue: state)
    }

    package func makeBootstrapProgressObserver() -> AsyncStream<LoomAuthenticatedSessionBootstrapProgress> {
        bootstrapProgressObservers.makeStream(initialValue: bootstrapProgress)
    }

    package func openStream(label: String?) async throws -> LoomMultiplexedStream {
        guard case .ready = state else {
            throw LoomHostError.protocolViolation("The broker-backed Loom session is not ready.")
        }
        if let label {
            let labelLength = label.lengthOfBytes(using: .utf8)
            guard labelLength <= LoomMessageLimits.maxStreamLabelBytes else {
                throw LoomHostError.protocolViolation(
                    "Broker-backed Loom stream labels must not exceed \(LoomMessageLimits.maxStreamLabelBytes) UTF-8 bytes."
                )
            }
        }

        let streamID = nextOutgoingStreamID
        guard streamID != 0 else {
            throw LoomHostError.protocolViolation("Broker-backed Loom session exhausted stream identifiers.")
        }
        nextOutgoingStreamID = streamID == .max ? 0 : streamID &+ 1

        let stream = makeStream(id: streamID, label: label)
        guard let lease = reliableSendAdmission.acquire() else {
            throw LoomHostError.protocolViolation(
                "The broker-backed Loom session is closed to reliable sends."
            )
        }
        defer { lease.release() }
        try await openHandler(connectionID, streamID, label)
        streams[streamID] = stream
        return stream
    }

    package func cancel() async {
        reliableSendAdmission.close()
        guard state != .cancelled else {
            return
        }
        state = .cancelled
        stateObservers.yield(.cancelled)
        finishAllStreams()
        await cancelHandler(connectionID)
    }

    package func handleRemoteStreamOpened(streamID: UInt16, label: String?) {
        guard streams[streamID] == nil else {
            return
        }
        let stream = makeStream(id: streamID, label: label)
        streams[streamID] = stream
        incomingStreamObservers.yield(stream)
    }

    package func handleRemoteStreamData(streamID: UInt16, payload: Data) {
        streams[streamID]?.yield(payload)
    }

    package func handleRemoteStreamClosed(streamID: UInt16) {
        guard let stream = streams.removeValue(forKey: streamID) else {
            return
        }
        stream.finishInbound()
    }

    package func handleStateChanged(_ newState: LoomAuthenticatedSessionState) {
        state = newState
        stateObservers.yield(newState)
        switch newState {
        case .ready,
             .handshaking,
             .idle:
            break
        case .cancelled,
             .failed:
            reliableSendAdmission.close()
            finishAllStreams()
        }
    }

    private func makeStream(id: UInt16, label: String?) -> LoomMultiplexedStream {
        let terminateHardCut: @Sendable () async -> Void = {
            [weak self, connectionID, hardCutHandler, reliableSendAdmission] in
            if let self {
                await self.terminateForReliableSendHardCut()
            } else {
                // A retained stream can outlive its virtual session. The shared IPC cut remains
                // mandatory because its broker request may still be suspended.
                await hardCutHandler(connectionID)
                await reliableSendAdmission.waitForQuiescence()
            }
        }
        return LoomMultiplexedStream(
            id: id,
            label: label,
            sendHandler: { [connectionID, sendHandler, reliableSendAdmission] data in
                guard let lease = reliableSendAdmission.acquire() else {
                    throw LoomHostError.protocolViolation("The broker-backed Loom session is closed to reliable sends.")
                }
                defer { lease.release() }
                try await sendHandler(connectionID, id, data)
            },
            hardDeadlineSendHandler: {
                [connectionID, sendHandler, reliableSendAdmission, terminateHardCut] data, deadline in
                let deadlineLeaseTransfer: LoomReliableSendLeaseTransfer
                switch reliableSendAdmission.acquire(before: deadline) {
                case let .admitted(lease):
                    // Admission and deadline observation share one lock, so an IPC request cannot
                    // enter through a task that begins running after its caller's deadline.
                    deadlineLeaseTransfer = LoomReliableSendLeaseTransfer(lease)
                case .expired:
                    // No lease or IPC request exists, so pre-admission expiry leaves the session open.
                    throw LoomError.timeout
                case .closed:
                    throw LoomHostError.protocolViolation("The broker-backed Loom session is closed to reliable sends.")
                }
                defer { deadlineLeaseTransfer.releaseIfOperationHasNotStarted() }
                try await withLoomQuiescingHardDeadline(
                    deadline,
                    closeAdmission: {
                        reliableSendAdmission.close()
                    },
                    releaseUnstartedOperation: {
                        // A hard cut can win before the spawned task takes ownership of its lease.
                        deadlineLeaseTransfer.releaseIfOperationHasNotStarted()
                    },
                    quiesce: terminateHardCut,
                    operation: {
                        guard let lease = deadlineLeaseTransfer.takeForOperation() else {
                            // The hard-cut winner already released a task that never entered IPC.
                            throw CancellationError()
                        }
                        defer { lease.release() }
                        try await sendHandler(connectionID, id, data)
                    }
                )
            },
            unreliableSendHandler: { [connectionID, sendHandler] data in
                try await sendHandler(connectionID, id, data)
            },
            queuedUnreliableSendHandler: { [connectionID, sendHandler] data, _, _, onComplete in
                do {
                    try await sendHandler(connectionID, id, data)
                    onComplete(nil)
                } catch {
                    onComplete(error)
                }
            },
            queuedUnreliableResetHandler: { _ in },
            closeHandler: { [connectionID, closeHandler, reliableSendAdmission] in
                guard let lease = reliableSendAdmission.acquire() else {
                    throw LoomHostError.protocolViolation(
                        "The broker-backed Loom session is closed to reliable sends."
                    )
                }
                defer { lease.release() }
                try await closeHandler(connectionID, id)
            }
        )
    }

    private func terminateForReliableSendHardCut() async {
        reliableSendAdmission.close()
        switch state {
        case .cancelled, .failed:
            break
        case .idle, .handshaking, .ready:
            state = .failed("Reliable broker-backed Loom stream send was hard-cut before completion.")
            stateObservers.yield(state)
            finishAllStreams()
        }
        // Closing the IPC socket bypasses the ordered request lane whose current request may be the
        // operation that crossed its deadline. The socket owner fails every pending continuation.
        await hardCutHandler(connectionID)
        await reliableSendAdmission.waitForQuiescence()
    }

    private func finishAllStreams() {
        let liveStreams = streams.values
        streams.removeAll(keepingCapacity: false)
        for stream in liveStreams {
            stream.finishQueuedOutbound()
            stream.finishInbound()
        }
        incomingStreamObservers.finish()
    }
}
