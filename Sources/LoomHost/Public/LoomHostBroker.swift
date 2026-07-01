//
//  LoomHostBroker.swift
//  LoomHost
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation
import Loom

#if os(macOS)
import Darwin

/// Leader-owned shared-host broker that multiplexes one Loom runtime across App Group clients.
public actor LoomHostBroker {
    public let configuration: LoomSharedHostConfiguration

    private let socketPath: String
    private let lockFileDescriptor: Int32
    private let runtimeFactory: @Sendable () async throws -> LoomHostRuntimeDependencies

    private var listenerFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var runtime: LoomHostRuntime?
    private var socketConnections: [UUID: LoomHostSocketConnection] = [:]
    private var clientIDBySocketID: [UUID: UUID] = [:]
    private var socketIDByClientID: [UUID: UUID] = [:]
    private var appByClientID: [UUID: LoomHostAppDescriptor] = [:]
    private var brokerConnections: [UUID: LoomHostBrokerConnectionState] = [:]

    package init(
        configuration: LoomSharedHostConfiguration,
        socketPath: String,
        lockFileDescriptor: Int32,
        runtimeFactory: @escaping @Sendable () async throws -> LoomHostRuntimeDependencies
    ) {
        self.configuration = configuration
        self.socketPath = socketPath
        self.lockFileDescriptor = lockFileDescriptor
        self.runtimeFactory = runtimeFactory
    }

    deinit {
        acceptTask?.cancel()
        if listenerFD >= 0 {
            Darwin.close(listenerFD)
        }
        Darwin.close(lockFileDescriptor)
        unlink(socketPath)
    }

    public func start() async throws {
        guard listenerFD < 0 else {
            return
        }

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = try makeAddress(for: socketPath)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }

        listenerFD = fd
        let broker = self
        acceptTask = Task.detached { [broker] in
            await Self.runAcceptLoop(listenerFD: fd) { acceptedFD in
                await broker.acceptClient(fileDescriptor: acceptedFD)
            }
        }
    }

    public func stop() async {
        let acceptTask = acceptTask
        self.acceptTask = nil
        acceptTask?.cancel()

        if listenerFD >= 0 {
            wakeAcceptLoop()
            Darwin.close(listenerFD)
            listenerFD = -1
        }

        let connections = Array(socketConnections.values)
        socketConnections.removeAll()
        clientIDBySocketID.removeAll()
        socketIDByClientID.removeAll()
        appByClientID.removeAll()

        let liveBrokerConnections = Array(brokerConnections.values)
        brokerConnections.removeAll()
        for connection in liveBrokerConnections {
            connection.invalidate()
            await connection.session.cancel()
        }

        if let runtime {
            await runtime.stop()
        }
        runtime = nil

        _ = await acceptTask?.result
        unlink(socketPath)
        for connection in connections {
            await connection.close()
        }
    }

    private static func runAcceptLoop(
        listenerFD: Int32,
        onAccept: @escaping @Sendable (Int32) async -> Void
    ) async {
        while !Task.isCancelled {
            let acceptedFD = Darwin.accept(listenerFD, nil, nil)
            if acceptedFD < 0 {
                if errno == EINTR {
                    continue
                }
                if Task.isCancelled || errno == EBADF {
                    break
                }
                continue
            }
            if Task.isCancelled {
                Darwin.close(acceptedFD)
                break
            }
            await onAccept(acceptedFD)
        }
    }

    private func wakeAcceptLoop() {
        let wakeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard wakeFD >= 0 else {
            return
        }
        defer {
            Darwin.close(wakeFD)
        }

        guard var address = try? makeAddress(for: socketPath) else {
            return
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(wakeFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func acceptClient(fileDescriptor: Int32) async {
        let socketID = UUID()
        let connection = LoomHostSocketConnection(
            fileDescriptor: fileDescriptor,
            onFrame: { [weak self] frame in
                guard let self else { return }
                await self.handle(frame: frame, socketID: socketID)
            },
            onClosed: { [weak self] in
                guard let self else { return }
                await self.handleSocketClosed(socketID)
            }
        )
        socketConnections[socketID] = connection
        await connection.startReading()
    }

    private func handle(frame: LoomHostIPCFrame, socketID: UUID) async {
        do {
            switch frame.message {
            case let .register(clientID, app):
                try register(clientID: clientID, app: app, socketID: socketID)
                let runtime = try await sharedRuntime()
                try await runtime.register(app: app)
                try await reply(
                    .registered(snapshot: await runtime.stateSnapshot()),
                    to: clientID,
                    requestID: frame.requestID
                )

            case let .unregister(clientID):
                try requireRegisteredClient(clientID, socketID: socketID)
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)
                await unregister(clientID: clientID)

            case let .refreshPeers(clientID):
                try requireRegisteredClient(clientID, socketID: socketID)
                if let runtime {
                    await runtime.refreshPeers()
                }
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)

            case let .startRemoteHosting(clientID, sessionID, publicHostForTCP):
                try requireRegisteredClient(clientID, socketID: socketID)
                let runtime = try await sharedRuntime()
                try await runtime.startRemoteHosting(
                    sessionID: sessionID,
                    publicHostForTCP: publicHostForTCP
                )
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)

            case let .stopRemoteHosting(clientID):
                try requireRegisteredClient(clientID, socketID: socketID)
                if let runtime {
                    await runtime.stopRemoteHosting()
                }
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)

            case let .connect(clientID, peerID):
                try requireRegisteredClient(clientID, socketID: socketID)
                let runtime = try await sharedRuntime()
                let established = try await runtime.connect(
                    to: peerID,
                    sourceAppID: try sourceAppID(for: clientID)
                )
                let descriptor = await registerBrokerConnection(
                    for: clientID,
                    session: established.session,
                    peer: established.peer
                )
                try await reply(.connected(descriptor), to: clientID, requestID: frame.requestID)

            case let .connectRemote(clientID, sessionID):
                try requireRegisteredClient(clientID, socketID: socketID)
                let runtime = try await sharedRuntime()
                let established = try await runtime.connect(
                    remoteSessionID: sessionID,
                    sourceAppID: try sourceAppID(for: clientID)
                )
                let descriptor = await registerBrokerConnection(
                    for: clientID,
                    session: established.session,
                    peer: established.peer
                )
                try await reply(.connected(descriptor), to: clientID, requestID: frame.requestID)

            case let .disconnect(clientID, connectionID):
                try requireRegisteredClient(clientID, socketID: socketID)
                try await disconnect(connectionID: connectionID, expectedClientID: clientID)
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)

            case let .openStream(clientID, connectionID, streamID, label):
                try requireRegisteredClient(clientID, socketID: socketID)
                try await openStream(
                    clientID: clientID,
                    connectionID: connectionID,
                    streamID: streamID,
                    label: label
                )
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)

            case let .streamData(clientID, connectionID, streamID, payloadBase64):
                try requireRegisteredClient(clientID, socketID: socketID)
                guard let payload = Data(base64Encoded: payloadBase64) else {
                    throw LoomHostError.protocolViolation("Received invalid stream payload encoding.")
                }
                try await sendStreamData(
                    clientID: clientID,
                    connectionID: connectionID,
                    streamID: streamID,
                    payload: payload
                )
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)

            case let .closeStream(clientID, connectionID, streamID):
                try requireRegisteredClient(clientID, socketID: socketID)
                try await closeStream(
                    clientID: clientID,
                    connectionID: connectionID,
                    streamID: streamID
                )
                try await reply(.reply(status: .ok), to: clientID, requestID: frame.requestID)

            case .reply,
                 .registered,
                 .stateChanged,
                 .connected,
                 .incomingConnection,
                 .connectionStateChanged,
                 .streamOpened,
                 .streamDataReceived,
                 .streamClosed:
                throw LoomHostError.protocolViolation("Broker received an unexpected client message.")
            }
        } catch {
            if let clientID = clientIDBySocketID[socketID] {
                try? await reply(
                    .reply(status: .failed(error.localizedDescription)),
                    to: clientID,
                    requestID: frame.requestID
                )
            }
        }
    }

    private func register(
        clientID: UUID,
        app: LoomHostAppDescriptor,
        socketID: UUID
    ) throws {
        if let registeredClientID = clientIDBySocketID[socketID],
           registeredClientID != clientID {
            throw LoomHostError.protocolViolation("Shared-host socket is already registered to another client.")
        }
        if let registeredSocketID = socketIDByClientID[clientID],
           registeredSocketID != socketID {
            throw LoomHostError.protocolViolation("Shared-host client is already registered on another socket.")
        }
        clientIDBySocketID[socketID] = clientID
        socketIDByClientID[clientID] = socketID
        appByClientID[clientID] = app
    }

    private func requireRegisteredClient(_ clientID: UUID, socketID: UUID) throws {
        guard clientIDBySocketID[socketID] == clientID,
              socketIDByClientID[clientID] == socketID else {
            throw LoomHostError.protocolViolation("Shared-host client is not registered on this socket.")
        }
    }

    private func sharedRuntime() async throws -> LoomHostRuntime {
        if let runtime {
            return runtime
        }
        let dependencies = try await runtimeFactory()
        let runtime = LoomHostRuntime(
            dependencies: dependencies,
            onStateChanged: { [weak self] snapshot in
                guard let self else { return }
                await self.broadcast(.stateChanged(snapshot: snapshot))
            },
            onIncomingSession: { [weak self] session in
                guard let self else { return }
                await self.handleIncomingSession(session)
            }
        )
        self.runtime = runtime
        return runtime
    }

    private func handleIncomingSession(_ session: LoomAuthenticatedSession) async {
        guard let sessionContext = await session.context else {
            await session.cancel()
            return
        }
        let targetAppID = LoomHostCatalogCodec.targetAppID(from: sessionContext.peerAdvertisement)
        let targetClientID: UUID? = if let targetAppID {
            appByClientID.first { $0.value.appID == targetAppID }?.key
        } else if appByClientID.count == 1 {
            appByClientID.keys.first
        } else {
            nil
        }
        guard let targetClientID,
              let runtime else {
            await session.cancel()
            return
        }
        do {
            let peer = try await runtime.describeIncomingSession(session)
            let descriptor = await registerBrokerConnection(
                for: targetClientID,
                session: session,
                peer: peer
            )
            try await send(.incomingConnection(descriptor), to: targetClientID)
        } catch {
            await session.cancel()
        }
    }

    private func registerBrokerConnection(
        for clientID: UUID,
        session: LoomAuthenticatedSession,
        peer: LoomHostPeerRecord
    ) async -> LoomHostConnectionDescriptor {
        let connectionID = UUID()
        let descriptor = LoomHostConnectionDescriptor(
            connectionID: connectionID,
            peer: peer,
            context: await session.context!
        )
        let state = LoomHostBrokerConnectionState(
            clientID: clientID,
            session: session,
            peer: peer
        )
        brokerConnections[connectionID] = state
        state.stateTask = Task { [weak self] in
            guard let self else { return }
            let stateStream = await session.makeStateObserver()
            for await sessionState in stateStream {
                let errorMessage = Self.errorMessage(for: sessionState)
                await self.handleConnectionStateChange(
                    connectionID: connectionID,
                    state: sessionState,
                    errorMessage: errorMessage
                )
            }
        }
        state.incomingStreamTask = Task { [weak self] in
            guard let self else { return }
            for await stream in session.makeIncomingStreamObserver() {
                await self.handleIncomingUnderlyingStream(
                    connectionID: connectionID,
                    stream: stream
                )
            }
        }
        return descriptor
    }

    private func disconnect(connectionID: UUID, expectedClientID: UUID) async throws {
        guard let state = brokerConnections[connectionID] else {
            throw LoomHostError.connectionNotFound(connectionID)
        }
        guard state.clientID == expectedClientID else {
            throw LoomHostError.protocolViolation("Shared-host connection ownership mismatch.")
        }
        brokerConnections.removeValue(forKey: connectionID)
        state.invalidate()
        await state.session.cancel()
    }

    private func openStream(
        clientID: UUID,
        connectionID: UUID,
        streamID: UInt16,
        label: String?
    ) async throws {
        guard let state = brokerConnections[connectionID] else {
            throw LoomHostError.connectionNotFound(connectionID)
        }
        guard state.clientID == clientID else {
            throw LoomHostError.protocolViolation("Shared-host connection ownership mismatch.")
        }
        let stream = try await state.session.openStream(label: label)
        state.streamsByClientStreamID[streamID] = stream
        state.startForwarding(stream: stream, streamID: streamID, broker: self, connectionID: connectionID)
    }

    private func sendStreamData(
        clientID: UUID,
        connectionID: UUID,
        streamID: UInt16,
        payload: Data
    ) async throws {
        guard let state = brokerConnections[connectionID] else {
            throw LoomHostError.connectionNotFound(connectionID)
        }
        guard state.clientID == clientID,
              let stream = state.streamsByClientStreamID[streamID] else {
            throw LoomHostError.protocolViolation("Shared-host stream ownership mismatch.")
        }
        try await stream.send(payload)
    }

    private func closeStream(
        clientID: UUID,
        connectionID: UUID,
        streamID: UInt16
    ) async throws {
        guard let state = brokerConnections[connectionID] else {
            throw LoomHostError.connectionNotFound(connectionID)
        }
        guard state.clientID == clientID,
              let stream = state.streamsByClientStreamID.removeValue(forKey: streamID) else {
            throw LoomHostError.protocolViolation("Shared-host stream ownership mismatch.")
        }
        try await stream.close()
        state.forwardingTasks[streamID]?.cancel()
        state.forwardingTasks.removeValue(forKey: streamID)
    }

    private func handleIncomingUnderlyingStream(
        connectionID: UUID,
        stream: LoomMultiplexedStream
    ) async {
        guard let state = brokerConnections[connectionID] else {
            return
        }
        let streamID = state.nextIncomingClientStreamID
        state.nextIncomingClientStreamID = state.nextIncomingClientStreamID == UInt16.max
            ? 0x8000
            : state.nextIncomingClientStreamID &+ 1
        state.streamsByClientStreamID[streamID] = stream
        try? await send(.streamOpened(connectionID: connectionID, streamID: streamID, label: stream.label), to: state.clientID)
        state.startForwarding(stream: stream, streamID: streamID, broker: self, connectionID: connectionID)
    }

    fileprivate func handleForwardedStreamClosed(
        connectionID: UUID,
        streamID: UInt16
    ) async {
        guard let state = brokerConnections[connectionID] else {
            return
        }
        state.streamsByClientStreamID.removeValue(forKey: streamID)
        state.forwardingTasks.removeValue(forKey: streamID)
        try? await send(.streamClosed(connectionID: connectionID, streamID: streamID), to: state.clientID)
    }

    fileprivate func handleForwardedStreamPayload(
        connectionID: UUID,
        streamID: UInt16,
        payload: Data
    ) async {
        guard let state = brokerConnections[connectionID] else {
            return
        }
        try? await send(
            .streamDataReceived(
                connectionID: connectionID,
                streamID: streamID,
                payloadBase64: payload.base64EncodedString()
            ),
            to: state.clientID
        )
    }

    private func handleConnectionStateChange(
        connectionID: UUID,
        state: LoomAuthenticatedSessionState,
        errorMessage: String?
    ) async {
        guard let connection = brokerConnections[connectionID] else {
            return
        }
        try? await send(
            .connectionStateChanged(
                connectionID: connectionID,
                state: state,
                errorMessage: errorMessage
            ),
            to: connection.clientID
        )
        if case .cancelled = state {
            brokerConnections.removeValue(forKey: connectionID)
            connection.invalidate()
        } else if case .failed = state {
            brokerConnections.removeValue(forKey: connectionID)
            connection.invalidate()
        }
    }

    private func unregister(clientID: UUID) async {
        if let appID = appByClientID[clientID]?.appID,
           let runtime {
            await runtime.unregister(appID: appID)
        }
        appByClientID.removeValue(forKey: clientID)
        if let socketID = socketIDByClientID.removeValue(forKey: clientID) {
            clientIDBySocketID.removeValue(forKey: socketID)
        }

        let ownedConnections = brokerConnections
            .filter { $0.value.clientID == clientID }
            .map(\.key)
        for connectionID in ownedConnections {
            if let state = brokerConnections.removeValue(forKey: connectionID) {
                state.invalidate()
                await state.session.cancel()
            }
        }
    }

    private func handleSocketClosed(_ socketID: UUID) async {
        if let clientID = clientIDBySocketID[socketID] {
            await unregister(clientID: clientID)
        }
        socketConnections.removeValue(forKey: socketID)
    }

    private func reply(
        _ message: LoomHostIPCMessage,
        to clientID: UUID,
        requestID: UUID?
    ) async throws {
        try await send(message, to: clientID, requestID: requestID)
    }

    private func send(
        _ message: LoomHostIPCMessage,
        to clientID: UUID,
        requestID: UUID? = nil
    ) async throws {
        guard let socketID = socketIDByClientID[clientID],
              let connection = socketConnections[socketID] else {
            throw LoomHostError.brokerUnavailable
        }
        try await connection.send(
            LoomHostIPCFrame(
                requestID: requestID,
                message: message
            )
        )
    }

    private func broadcast(_ message: LoomHostIPCMessage) async {
        for clientID in appByClientID.keys {
            try? await send(message, to: clientID, requestID: nil)
        }
    }

    private static func errorMessage(for state: LoomAuthenticatedSessionState) -> String? {
        switch state {
        case let .failed(message):
            message
        case .idle,
             .handshaking,
             .ready,
             .cancelled:
            nil
        }
    }

    private func sourceAppID(for clientID: UUID) throws -> String {
        guard let appID = appByClientID[clientID]?.appID else {
            throw LoomHostError.protocolViolation("Shared-host client must register before connecting.")
        }
        return appID
    }
}

private final class LoomHostBrokerConnectionState: @unchecked Sendable {
    let clientID: UUID
    let session: LoomAuthenticatedSession
    let peer: LoomHostPeerRecord

    var streamsByClientStreamID: [UInt16: LoomMultiplexedStream] = [:]
    var forwardingTasks: [UInt16: Task<Void, Never>] = [:]
    var stateTask: Task<Void, Never>?
    var incomingStreamTask: Task<Void, Never>?
    var nextIncomingClientStreamID: UInt16 = 0x8000

    init(
        clientID: UUID,
        session: LoomAuthenticatedSession,
        peer: LoomHostPeerRecord
    ) {
        self.clientID = clientID
        self.session = session
        self.peer = peer
    }

    func invalidate() {
        stateTask?.cancel()
        incomingStreamTask?.cancel()
        for task in forwardingTasks.values {
            task.cancel()
        }
        forwardingTasks.removeAll()
        streamsByClientStreamID.removeAll()
    }

    func startForwarding(
        stream: LoomMultiplexedStream,
        streamID: UInt16,
        broker: LoomHostBroker,
        connectionID: UUID
    ) {
        forwardingTasks[streamID]?.cancel()
        forwardingTasks[streamID] = Task { [weak broker] in
            guard let broker else { return }
            for await payload in stream.incomingBytes {
                await broker.handleForwardedStreamPayload(
                    connectionID: connectionID,
                    streamID: streamID,
                    payload: payload
                )
            }
            await broker.handleForwardedStreamClosed(
                connectionID: connectionID,
                streamID: streamID
            )
        }
    }
}
#else
/// Leader-owned shared-host broker that multiplexes one Loom runtime across App Group clients.
public actor LoomHostBroker {
    public let configuration: LoomSharedHostConfiguration

    package init(
        configuration: LoomSharedHostConfiguration,
        socketPath _: String,
        lockFileDescriptor _: Int32,
        runtimeFactory _: @escaping @Sendable () async throws -> LoomHostRuntimeDependencies
    ) {
        self.configuration = configuration
    }

    public func start() async throws {
        throw LoomHostError.unsupportedPlatform
    }

    public func stop() async {}
}
#endif
