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
        cancelHandler: @escaping @Sendable (UUID) async -> Void
    ) {
        self.connectionID = connectionID
        self.transportKind = transportKind
        self.context = context
        self.openHandler = openHandler
        self.sendHandler = sendHandler
        self.closeHandler = closeHandler
        self.cancelHandler = cancelHandler
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
        try await openHandler(connectionID, streamID, label)
        streams[streamID] = stream
        return stream
    }

    package func cancel() async {
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
            finishAllStreams()
        }
    }

    private func makeStream(id: UInt16, label: String?) -> LoomMultiplexedStream {
        LoomMultiplexedStream(
            id: id,
            label: label,
            sendHandler: { [connectionID, sendHandler] data in
                try await sendHandler(connectionID, id, data)
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
            closeHandler: { [connectionID, closeHandler] in
                try await closeHandler(connectionID, id)
            }
        )
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
