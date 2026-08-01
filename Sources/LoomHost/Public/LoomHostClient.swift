//
//  LoomHostClient.swift
//  LoomHost
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation
import Loom

#if os(macOS)
import Darwin

package struct LoomHostClientConnection: Sendable {
    package let descriptor: LoomHostConnectionDescriptor
    package let session: LoomVirtualAppSession
}

private struct LoomHostPendingReply {
    let continuation: CheckedContinuation<LoomHostIPCMessage, Error>
    let socketGeneration: UInt64
    let cancellation: LoomHostRequestCancellation
    let submissionTask: Task<Void, Never>
}

private final class LoomHostRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelledStorage = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledStorage
    }

    func cancel() {
        lock.lock()
        isCancelledStorage = true
        lock.unlock()
    }
}

/// Client for the App Group-scoped shared-host broker.
public actor LoomHostClient {
    public let configuration: LoomSharedHostConfiguration

    private let clientID = UUID()
    private let runtimeFactory: (@Sendable () async throws -> LoomHostRuntimeDependencies)?
    private let stateBroadcaster = LoomAsyncBroadcaster<LoomHostStateSnapshot>()
    private let incomingConnectionBroadcaster = LoomAsyncBroadcaster<LoomHostClientConnection>()

    private var broker: LoomHostBroker?
    private var socket: LoomHostSocketConnection?
    private var currentSnapshot = LoomHostStateSnapshot(
        peers: [],
        isRunning: false,
        isRemoteHosting: false,
        lastErrorMessage: nil
    )
    private var isStarted = false
    private var activeSocketGeneration: UInt64 = 0
    private var reconnectTask: Task<Void, Never>?
    private var reconnectToken: UUID?
    private var pendingReplies: [UUID: LoomHostPendingReply] = [:]
    private var sessionsByConnectionID: [UUID: LoomVirtualAppSession] = [:]

    public init(configuration: LoomSharedHostConfiguration) {
        self.configuration = configuration
        runtimeFactory = nil
    }

    package init(
        configuration: LoomSharedHostConfiguration,
        runtimeFactory: @escaping @Sendable () async throws -> LoomHostRuntimeDependencies
    ) {
        self.configuration = configuration
        self.runtimeFactory = runtimeFactory
    }

    deinit {
        stateBroadcaster.finish()
        incomingConnectionBroadcaster.finish()
    }

    package func makeStateStream() -> AsyncStream<LoomHostStateSnapshot> {
        stateBroadcaster.makeStream(initialValue: currentSnapshot)
    }

    package func makeIncomingConnectionStream() -> AsyncStream<LoomHostClientConnection> {
        incomingConnectionBroadcaster.makeStream()
    }

    package func start() async throws {
        isStarted = true
        try await connectAndRegister()
    }

    package func stop() async {
        isStarted = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectToken = nil
        let closingSocket = socket
        if socket != nil {
            _ = try? await request(.unregister(clientID: clientID))
        }
        // Invalidate callbacks before closing so a late EOF from this descriptor cannot tear down
        // a connection opened by a subsequent start.
        advanceSocketGeneration()
        socket = nil
        let liveSessions = Array(sessionsByConnectionID.values)
        sessionsByConnectionID.removeAll()
        for session in liveSessions {
            await session.handleStateChanged(.cancelled)
        }
        await closingSocket?.close()
    }

    package func refreshPeers() async throws {
        _ = try await request(.refreshPeers(clientID: clientID))
    }

    package func startRemoteHosting(
        sessionID: String,
        publicHostForTCP: String?
    ) async throws {
        _ = try await request(
            .startRemoteHosting(
                clientID: clientID,
                sessionID: sessionID,
                publicHostForTCP: publicHostForTCP
            )
        )
    }

    package func stopRemoteHosting() async throws {
        _ = try await request(.stopRemoteHosting(clientID: clientID))
    }

    package func connect(to peerID: LoomPeerID) async throws -> LoomHostClientConnection {
        let reply = try await request(.connect(clientID: clientID, peerID: peerID))
        guard case let .connected(descriptor) = reply else {
            throw LoomHostError.protocolViolation("Broker returned an unexpected connect response.")
        }
        return makeConnection(from: descriptor)
    }

    package func connect(remoteSessionID: String) async throws -> LoomHostClientConnection {
        let reply = try await request(
            .connectRemote(
                clientID: clientID,
                sessionID: remoteSessionID
            )
        )
        guard case let .connected(descriptor) = reply else {
            throw LoomHostError.protocolViolation("Broker returned an unexpected remote connect response.")
        }
        return makeConnection(from: descriptor)
    }

    package func disconnect(connectionID: UUID) async throws {
        _ = try await request(
            .disconnect(
                clientID: clientID,
                connectionID: connectionID
            )
        )
    }

    private func connectAndRegister() async throws {
        if socket == nil {
            let generation = advanceSocketGeneration()
            let connection = try await connectTransport(socketGeneration: generation)
            guard isStarted,
                  socket == nil,
                  activeSocketGeneration == generation else {
                await connection.close()
                throw LoomHostError.brokerUnavailable
            }
            socket = connection
        }

        let reply = try await request(
            .register(
                clientID: clientID,
                app: configuration.app
            )
        )
        guard case let .registered(snapshot) = reply else {
            throw LoomHostError.protocolViolation("Broker returned an unexpected register response.")
        }
        currentSnapshot = snapshot
        stateBroadcaster.yield(snapshot)
    }

    private func connectTransport(socketGeneration: UInt64) async throws -> LoomHostSocketConnection {
        let layout = try Self.socketLayout(for: configuration)
        try FileManager.default.createDirectory(
            at: layout.directoryURL,
            withIntermediateDirectories: true
        )

        if let connection = try? await LoomHostSocketConnection.connect(
            to: layout.socketURL.path,
            onFrame: { [weak self] frame in
                guard let self else { return }
                await self.handle(frame: frame, socketGeneration: socketGeneration)
            },
            onClosed: { [weak self] in
                guard let self else { return }
                await self.handleSocketClosed(socketGeneration: socketGeneration)
            }
        ) {
            return connection
        }

        try await maybeLaunchBroker(layout: layout)

        for _ in 0..<20 {
            if let connection = try? await LoomHostSocketConnection.connect(
                to: layout.socketURL.path,
                onFrame: { [weak self] frame in
                    guard let self else { return }
                    await self.handle(frame: frame, socketGeneration: socketGeneration)
                },
                onClosed: { [weak self] in
                    guard let self else { return }
                    await self.handleSocketClosed(socketGeneration: socketGeneration)
                }
            ) {
                return connection
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw LoomHostError.brokerUnavailable
    }

    private func maybeLaunchBroker(layout: LoomHostSocketLayout) async throws {
        guard broker == nil else {
            return
        }
        guard let runtimeFactory else {
            return
        }

        let lockFD = open(layout.lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            return
        }

        let broker = LoomHostBroker(
            configuration: configuration,
            socketPath: layout.socketURL.path,
            lockFileDescriptor: lockFD,
            runtimeFactory: runtimeFactory
        )
        try await broker.start()
        self.broker = broker
    }

    private func request(
        _ message: LoomHostIPCMessage,
        expectedSocketGeneration: UInt64? = nil
    ) async throws -> LoomHostIPCMessage {
        try Task.checkCancellation()
        if let expectedSocketGeneration {
            guard socket != nil,
                  activeSocketGeneration == expectedSocketGeneration else {
                // A virtual session belongs to the IPC generation that created it. Retained
                // streams from a retired session may fail, but cannot reconnect through a new one.
                throw LoomHostError.brokerUnavailable
            }
        }
        if socket == nil {
            try Task.checkCancellation()
            try await connectAndRegister()
        }
        try Task.checkCancellation()
        guard let socket else {
            throw LoomHostError.brokerUnavailable
        }
        let socketGeneration = activeSocketGeneration
        if let expectedSocketGeneration,
           expectedSocketGeneration != socketGeneration {
            throw LoomHostError.brokerUnavailable
        }

        let requestID = UUID()
        let cancellation = LoomHostRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard self.socket != nil,
                      self.activeSocketGeneration == socketGeneration else {
                    continuation.resume(throwing: LoomHostError.brokerUnavailable)
                    return
                }
                let submissionTask = Task { [weak self] in
                    guard let self else { return }
                    await self.submitPendingRequest(
                        requestID: requestID,
                        message: message,
                        socket: socket,
                        socketGeneration: socketGeneration,
                        cancellation: cancellation
                    )
                }
                pendingReplies[requestID] = LoomHostPendingReply(
                    continuation: continuation,
                    socketGeneration: socketGeneration,
                    cancellation: cancellation,
                    submissionTask: submissionTask
                )
            }
        } onCancel: { [weak self] in
            // Set the shared flag synchronously so submission cannot win actor scheduling against
            // the cancellation cleanup task below.
            cancellation.cancel()
            Task {
                await self?.cancelPendingReply(requestID: requestID)
            }
        }
    }

    private func submitPendingRequest(
        requestID: UUID,
        message: LoomHostIPCMessage,
        socket: LoomHostSocketConnection,
        socketGeneration: UInt64,
        cancellation: LoomHostRequestCancellation
    ) async {
        guard !Task.isCancelled,
              !cancellation.isCancelled,
              let pendingReply = pendingReplies[requestID],
              !pendingReply.cancellation.isCancelled,
              pendingReply.socketGeneration == socketGeneration,
              activeSocketGeneration == socketGeneration,
              self.socket === socket else {
            failPendingReply(requestID: requestID, error: CancellationError())
            return
        }
        do {
            // Submission is a separate task because the checked-continuation installation is
            // synchronous. Recheck cancellation here so a retired request cannot reach the socket.
            try Task.checkCancellation()
            guard !cancellation.isCancelled else {
                throw CancellationError()
            }
            try await socket.send(
                LoomHostIPCFrame(
                    requestID: requestID,
                    message: message
                )
            )
        } catch {
            failPendingReply(requestID: requestID, error: error)
        }
    }

    private func cancelPendingReply(requestID: UUID) {
        guard let pendingReply = pendingReplies.removeValue(forKey: requestID) else {
            return
        }
        pendingReply.cancellation.cancel()
        pendingReply.submissionTask.cancel()
        pendingReply.continuation.resume(throwing: CancellationError())
    }

    private func handle(frame: LoomHostIPCFrame, socketGeneration: UInt64) async {
        // A late reader task from a closed descriptor must not deliver replies or stream state
        // into the client after a newer broker connection has been installed.
        guard socketGeneration == activeSocketGeneration, socket != nil else {
            return
        }
        if let requestID = frame.requestID,
           let pendingReply = pendingReplies.removeValue(forKey: requestID) {
            pendingReply.submissionTask.cancel()
            switch frame.message {
            case let .reply(status):
                switch status {
                case .ok:
                    pendingReply.continuation.resume(returning: frame.message)
                case let .failed(message):
                    pendingReply.continuation.resume(throwing: LoomHostError.remoteFailure(message))
                }
            default:
                pendingReply.continuation.resume(returning: frame.message)
            }
            return
        }

        switch frame.message {
        case let .registered(snapshot),
             let .stateChanged(snapshot):
            currentSnapshot = snapshot
            stateBroadcaster.yield(snapshot)

        case let .incomingConnection(descriptor):
            let connection = makeConnection(
                from: descriptor,
                socketGeneration: socketGeneration
            )
            incomingConnectionBroadcaster.yield(connection)

        case let .connectionStateChanged(connectionID, state, _):
            if let session = sessionsByConnectionID[connectionID] {
                await session.handleStateChanged(state)
            }
            switch state {
            case .cancelled,
                 .failed:
                sessionsByConnectionID.removeValue(forKey: connectionID)
            case .idle,
                 .handshaking,
                 .ready:
                break
            }

        case let .streamOpened(connectionID, streamID, label):
            if let session = sessionsByConnectionID[connectionID] {
                await session.handleRemoteStreamOpened(streamID: streamID, label: label)
            }

        case let .streamDataReceived(connectionID, streamID, payloadBase64):
            guard let payload = Data(base64Encoded: payloadBase64),
                  let session = sessionsByConnectionID[connectionID] else {
                return
            }
            await session.handleRemoteStreamData(streamID: streamID, payload: payload)

        case let .streamClosed(connectionID, streamID):
            if let session = sessionsByConnectionID[connectionID] {
                await session.handleRemoteStreamClosed(streamID: streamID)
            }

        case .reply,
             .connect,
             .connectRemote,
             .refreshPeers,
             .register,
             .unregister,
             .disconnect,
             .openStream,
             .streamData,
             .closeStream,
             .startRemoteHosting,
             .stopRemoteHosting,
             .connected:
            break
        }
    }

    private func handleSocketClosed(socketGeneration: UInt64) async {
        // Each descriptor has a distinct generation. Ignore an old close callback after the
        // replacement socket has become authoritative.
        guard socketGeneration == activeSocketGeneration else {
            return
        }
        socket = nil
        advanceSocketGeneration()
        failAllPendingReplies(error: LoomHostError.brokerUnavailable)

        let liveSessions = Array(sessionsByConnectionID.values)
        sessionsByConnectionID.removeAll()
        for session in liveSessions {
            await session.handleStateChanged(.failed("shared-host-broker-disconnected"))
        }

        guard isStarted else {
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else {
            return
        }
        let token = UUID()
        reconnectToken = token
        // Reconnection is intentionally detached from the hard-cut call path: an expired stream
        // send fails immediately instead of waiting for broker discovery or registration.
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.reconnect(token: token)
        }
    }

    private func reconnect(token: UUID) async {
        defer {
            if reconnectToken == token {
                reconnectToken = nil
                reconnectTask = nil
            }
        }

        for _ in 0..<10 {
            guard !Task.isCancelled,
                  isStarted,
                  reconnectToken == token,
                  socket == nil else {
                return
            }
            do {
                try await connectAndRegister()
                return
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        guard isStarted, reconnectToken == token else {
            return
        }
        currentSnapshot = LoomHostStateSnapshot(
            peers: [],
            isRunning: false,
            isRemoteHosting: false,
            lastErrorMessage: LoomHostError.brokerUnavailable.localizedDescription
        )
        stateBroadcaster.yield(currentSnapshot)
    }

    private func failPendingReply(
        requestID: UUID,
        error: Error
    ) {
        guard let pendingReply = pendingReplies.removeValue(forKey: requestID) else {
            return
        }
        pendingReply.cancellation.cancel()
        pendingReply.submissionTask.cancel()
        pendingReply.continuation.resume(throwing: error)
    }

    private func failAllPendingReplies(error: Error) {
        let liveReplies = Array(pendingReplies.values)
        pendingReplies.removeAll()
        for pendingReply in liveReplies {
            pendingReply.cancellation.cancel()
            pendingReply.submissionTask.cancel()
            pendingReply.continuation.resume(throwing: error)
        }
    }

    private func makeConnection(
        from descriptor: LoomHostConnectionDescriptor,
        socketGeneration: UInt64? = nil
    ) -> LoomHostClientConnection {
        if let existing = sessionsByConnectionID[descriptor.connectionID] {
            return LoomHostClientConnection(descriptor: descriptor, session: existing)
        }
        let sessionSocketGeneration = socketGeneration ?? activeSocketGeneration
        let session = LoomVirtualAppSession(
            connectionID: descriptor.connectionID,
            transportKind: descriptor.context.transportKind,
            context: descriptor.context,
            openHandler: { [weak self] connectionID, streamID, label in
                guard let self else { throw LoomHostError.brokerUnavailable }
                _ = try await self.request(
                    .openStream(
                        clientID: self.clientID,
                        connectionID: connectionID,
                        streamID: streamID,
                        label: label
                    ),
                    expectedSocketGeneration: sessionSocketGeneration
                )
            },
            sendHandler: { [weak self] connectionID, streamID, payload in
                guard let self else { throw LoomHostError.brokerUnavailable }
                _ = try await self.request(
                    .streamData(
                        clientID: self.clientID,
                        connectionID: connectionID,
                        streamID: streamID,
                        payloadBase64: payload.base64EncodedString()
                    ),
                    expectedSocketGeneration: sessionSocketGeneration
                )
            },
            closeHandler: { [weak self] connectionID, streamID in
                guard let self else { throw LoomHostError.brokerUnavailable }
                _ = try await self.request(
                    .closeStream(
                        clientID: self.clientID,
                        connectionID: connectionID,
                        streamID: streamID
                    ),
                    expectedSocketGeneration: sessionSocketGeneration
                )
            },
            cancelHandler: { [weak self] connectionID in
                guard let self else { return }
                _ = try? await self.request(
                    .disconnect(
                        clientID: self.clientID,
                        connectionID: connectionID
                    ),
                    expectedSocketGeneration: sessionSocketGeneration
                )
            },
            hardCutHandler: { [weak self] _ in
                guard let self else { return }
                await self.hardCutSharedIPCSocket(
                    expectedSocketGeneration: sessionSocketGeneration
                )
            }
        )
        sessionsByConnectionID[descriptor.connectionID] = session
        return LoomHostClientConnection(descriptor: descriptor, session: session)
    }

    @discardableResult
    private func advanceSocketGeneration() -> UInt64 {
        // Change the token before every descriptor install or retirement so stale callbacks can
        // never mutate the active connection, even if an OS descriptor number is reused.
        activeSocketGeneration = activeSocketGeneration == UInt64.max
            ? 1
            : activeSocketGeneration &+ 1
        return activeSocketGeneration
    }

    private func hardCutSharedIPCSocket(expectedSocketGeneration: UInt64) async {
        // A broker request may itself be suspended in the expired stream send. Closing the shared
        // IPC socket is the only existing out-of-band signal and also fails every pending reply.
        guard activeSocketGeneration == expectedSocketGeneration else {
            return
        }
        failAllPendingReplies(error: LoomHostError.brokerUnavailable)
        guard let socket else {
            return
        }
        // This synchronous fence is intentionally nonisolated from the socket actor so it can
        // interrupt that actor while `Darwin.write` is backpressured.
        socket.hardCloseNow()
        await socket.close()
    }

    private static func socketLayout(for configuration: LoomSharedHostConfiguration) throws -> LoomHostSocketLayout {
        let directoryURL: URL
        if let directoryURLOverride = configuration.directoryURLOverride {
            directoryURL = directoryURLOverride
        } else if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) {
            directoryURL = appGroupURL.appendingPathComponent("LoomHost", isDirectory: true)
        } else {
            throw LoomHostError.invalidSharedContainer(
                "The shared-host App Group \(configuration.appGroupIdentifier) is unavailable."
            )
        }

        return LoomHostSocketLayout(
            directoryURL: directoryURL,
            socketURL: directoryURL.appendingPathComponent("\(configuration.socketName).sock"),
            lockURL: directoryURL.appendingPathComponent("\(configuration.socketName).lock")
        )
    }
}

package struct LoomHostSocketLayout: Sendable {
    package let directoryURL: URL
    package let socketURL: URL
    package let lockURL: URL
}
#else
package struct LoomHostClientConnection: Sendable {
    package let descriptor: LoomHostConnectionDescriptor
    package let session: any LoomSessionProtocol
}

/// Client for the App Group-scoped shared-host broker.
public actor LoomHostClient {
    public let configuration: LoomSharedHostConfiguration

    public init(configuration: LoomSharedHostConfiguration) {
        self.configuration = configuration
    }

    package func makeStateStream() -> AsyncStream<LoomHostStateSnapshot> {
        AsyncStream { continuation in
            continuation.yield(
                LoomHostStateSnapshot(
                    peers: [],
                    isRunning: false,
                    isRemoteHosting: false,
                    lastErrorMessage: LoomHostError.unsupportedPlatform.localizedDescription
                )
            )
            continuation.finish()
        }
    }

    package func makeIncomingConnectionStream() -> AsyncStream<LoomHostClientConnection> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    package func start() async throws {
        throw LoomHostError.unsupportedPlatform
    }

    package func stop() async {}

    package func refreshPeers() async throws {
        throw LoomHostError.unsupportedPlatform
    }

    package func startRemoteHosting(
        sessionID: String,
        publicHostForTCP: String?
    ) async throws {
        throw LoomHostError.unsupportedPlatform
    }

    package func stopRemoteHosting() async throws {
        throw LoomHostError.unsupportedPlatform
    }

    package func connect(to peerID: LoomPeerID) async throws -> LoomHostClientConnection {
        throw LoomHostError.unsupportedPlatform
    }

    package func connect(remoteSessionID: String) async throws -> LoomHostClientConnection {
        throw LoomHostError.unsupportedPlatform
    }

    package func disconnect(connectionID: UUID) async throws {
        throw LoomHostError.unsupportedPlatform
    }
}
#endif
