//
//  LoomNIOListener.swift
//  LoomNetworkingNIO
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking
import NIOCore
import NIOPosix

actor LoomNIOStreamListener: LoomNetworkListener {
    nonisolated let transportKind: LoomTransportKind = .tcp

    private let eventLoopGroup: any EventLoopGroup
    private let connectionStream: AsyncStream<any LoomNetworkConnection>
    private let connectionContinuation: AsyncStream<any LoomNetworkConnection>.Continuation
    private var listenerChannel: (any Channel)?
    private var isStarting = false
    private var isCancelled = false

    init(eventLoopGroup: any EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
        let (stream, continuation) = AsyncStream.makeStream(
            of: (any LoomNetworkConnection).self,
            bufferingPolicy: .bufferingNewest(64)
        )
        connectionStream = stream
        connectionContinuation = continuation
    }

    func start(port: UInt16) async throws -> UInt16 {
        guard listenerChannel == nil, !isStarting, !isCancelled else {
            throw LoomNetworkError(
                code: .invalidConfiguration,
                detail: "SwiftNIO stream listener has already started or was cancelled."
            )
        }
        isStarting = true

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(
                ChannelOptions.Types.SocketOption(level: .ipv6, name: .ipv6_v6only),
                value: 0
            )
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(.socketOption(.so_keepalive), value: 1)
            .childChannelInitializer { [self] channel in
                guard let remoteEndpoint = LoomNIOUtilities.endpoint(for: channel.remoteAddress) else {
                    return channel.eventLoop.makeFailedFuture(
                        LoomNetworkError(
                            code: .other,
                            detail: "Accepted stream has no representable remote endpoint."
                        )
                    )
                }
                let connection = LoomNIOChannelConnection(
                    acceptedChannel: channel,
                    transportKind: .tcp,
                    remoteEndpoint: remoteEndpoint,
                    localEndpoint: LoomNIOUtilities.endpoint(for: channel.localAddress)
                )
                return channel.pipeline.addHandler(
                    LoomNIOStreamChannelHandler(connection: connection)
                ).map {
                    Task {
                        await self.accept(connection)
                    }
                }
            }

        do {
            let channel = try await bootstrap.bind(host: "::", port: Int(port)).get()
            guard !isCancelled else {
                try? await channel.close().get()
                throw LoomNetworkError(code: .cancelled, detail: "Stream listener cancelled while starting.")
            }
            listenerChannel = channel
            isStarting = false
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.listenerDidClose()
                }
            }
            guard let actualPort = channel.localAddress?.port,
                  let actualPort = UInt16(exactly: actualPort) else {
                try? await channel.close().get()
                throw LoomNetworkError(code: .other, detail: "Bound stream listener has no valid port.")
            }
            return actualPort
        } catch {
            isStarting = false
            listenerChannel = nil
            throw LoomNIOUtilities.networkError(error)
        }
    }

    func makeConnectionStream() -> AsyncStream<any LoomNetworkConnection> {
        connectionStream
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        connectionContinuation.finish()
        if let listenerChannel {
            try? await listenerChannel.close().get()
        }
        listenerChannel = nil
    }

    private func accept(_ connection: LoomNIOChannelConnection) async {
        guard !isCancelled else {
            await connection.cancel()
            return
        }
        switch connectionContinuation.yield(connection) {
        case .enqueued:
            break
        case let .dropped(droppedConnection):
            await droppedConnection.cancel()
        case .terminated:
            await connection.cancel()
        @unknown default:
            await connection.cancel()
        }
    }

    private func listenerDidClose() {
        listenerChannel = nil
        if !isCancelled {
            isCancelled = true
            connectionContinuation.finish()
        }
    }
}

actor LoomNIODatagramListener: LoomNetworkListener {
    nonisolated let transportKind: LoomTransportKind = .udp

    private let eventLoopGroup: any EventLoopGroup
    private let connectionStream: AsyncStream<any LoomNetworkConnection>
    private let connectionContinuation: AsyncStream<any LoomNetworkConnection>.Continuation
    private let hub: LoomNIODatagramHub
    private var listenerChannel: (any Channel)?
    private var isStarting = false
    private var isCancelled = false

    init(eventLoopGroup: any EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
        let (stream, continuation) = AsyncStream.makeStream(
            of: (any LoomNetworkConnection).self,
            bufferingPolicy: .bufferingNewest(64)
        )
        connectionStream = stream
        connectionContinuation = continuation
        hub = LoomNIODatagramHub { connection in
            switch continuation.yield(connection) {
            case .enqueued:
                break
            case let .dropped(droppedConnection):
                await droppedConnection.cancel()
            case .terminated:
                await connection.cancel()
            @unknown default:
                await connection.cancel()
            }
        }
    }

    func start(port: UInt16) async throws -> UInt16 {
        guard listenerChannel == nil, !isStarting, !isCancelled else {
            throw LoomNetworkError(
                code: .invalidConfiguration,
                detail: "SwiftNIO datagram listener has already started or was cancelled."
            )
        }
        isStarting = true

        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(
                ChannelOptions.Types.SocketOption(level: .ipv6, name: .ipv6_v6only),
                value: 0
            )
            .channelInitializer { [hub] channel in
                channel.pipeline.addHandler(LoomNIODatagramDemultiplexer(hub: hub))
            }

        do {
            let channel = try await bootstrap.bind(host: "::", port: Int(port)).get()
            guard !isCancelled else {
                try? await channel.close().get()
                throw LoomNetworkError(code: .cancelled, detail: "Datagram listener cancelled while starting.")
            }
            listenerChannel = channel
            isStarting = false
            guard let actualPort = channel.localAddress?.port,
                  let actualPort = UInt16(exactly: actualPort),
                  let localEndpoint = LoomNIOUtilities.endpoint(for: channel.localAddress) else {
                try? await channel.close().get()
                throw LoomNetworkError(code: .other, detail: "Bound datagram listener has no valid endpoint.")
            }
            await hub.attach(channel: channel, localEndpoint: localEndpoint)
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.listenerDidClose()
                }
            }
            return actualPort
        } catch {
            isStarting = false
            listenerChannel = nil
            throw LoomNIOUtilities.networkError(error)
        }
    }

    func makeConnectionStream() -> AsyncStream<any LoomNetworkConnection> {
        connectionStream
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        connectionContinuation.finish()
        await hub.cancel()
        if let listenerChannel {
            try? await listenerChannel.close().get()
        }
        listenerChannel = nil
    }

    private func listenerDidClose() {
        listenerChannel = nil
        if !isCancelled {
            isCancelled = true
            connectionContinuation.finish()
        }
    }
}

private actor LoomNIODatagramHub {
    typealias ConnectionHandler = @Sendable (any LoomNetworkConnection) async -> Void

    private let onConnection: ConnectionHandler
    private var channel: (any Channel)?
    private var localEndpoint: LoomNetworkEndpoint?
    private var connections: [SocketAddress: LoomNIOSharedDatagramConnection] = [:]
    private var terminalError: LoomNetworkError?

    private static let maximumConnections = 4_096

    init(onConnection: @escaping ConnectionHandler) {
        self.onConnection = onConnection
    }

    func attach(channel: any Channel, localEndpoint: LoomNetworkEndpoint) {
        self.channel = channel
        self.localEndpoint = localEndpoint
    }

    func receive(_ envelope: AddressedEnvelope<ByteBuffer>) async {
        guard terminalError == nil, let channel, let localEndpoint else { return }
        let remoteAddress = envelope.remoteAddress
        let connection: LoomNIOSharedDatagramConnection
        if let existing = connections[remoteAddress] {
            connection = existing
        } else {
            guard connections.count < Self.maximumConnections else { return }
            guard let remoteEndpoint = LoomNIOUtilities.endpoint(for: remoteAddress) else { return }
            let newConnection = LoomNIOSharedDatagramConnection(
                channel: channel,
                remoteAddress: remoteAddress,
                remoteEndpoint: remoteEndpoint,
                localEndpoint: localEndpoint,
                onCancel: { [weak self] address, identity in
                    guard let self else { return }
                    await self.remove(address, identity: identity)
                },
                onHardCancel: { [weak self] address, identity in
                    guard let self else { return }
                    await self.hardCancel(address, identity: identity)
                }
            )
            connections[remoteAddress] = newConnection
            connection = newConnection
            await onConnection(newConnection)
        }
        await connection.receiveInbound(Data(envelope.data.readableBytesView))
    }

    func fail(_ error: LoomNetworkError) async {
        guard terminalError == nil else { return }
        terminalError = error
        let currentConnections = connections.values
        connections.removeAll(keepingCapacity: false)
        for connection in currentConnections {
            await connection.fail(error)
        }
    }

    func cancel() async {
        let currentConnections = connections.values
        connections.removeAll(keepingCapacity: false)
        for connection in currentConnections {
            await connection.cancelFromListener()
        }
        channel = nil
    }

    private func remove(_ address: SocketAddress, identity: UUID) {
        guard connections[address]?.identity == identity else { return }
        connections.removeValue(forKey: address)
    }

    private func hardCancel(_ address: SocketAddress, identity: UUID) async {
        guard terminalError == nil else { return }
        if let currentConnection = connections[address],
           currentConnection.identity != identity {
            return
        }
        // NIO cannot retract one datagram after it enters a shared channel. A listener-wide close is
        // the smallest hard boundary that proves no late ordered write survives, so every peer is
        // intentionally retired rather than claiming false per-peer quiescence.
        terminalError = LoomNetworkError(
            code: .cancelled,
            detail: "Shared datagram channel hard-cut after an ordered send deadline."
        )
        let sharedChannel = channel
        channel = nil
        let currentConnections = connections.values
        connections.removeAll(keepingCapacity: false)
        for connection in currentConnections {
            await connection.cancelFromListener()
        }
        if let sharedChannel {
            try? await sharedChannel.close().get()
        }
    }
}

private actor LoomNIOSharedDatagramConnection: LoomNetworkConnection {
    private struct ReceiveWaiter {
        let maximumBytes: Int
        let continuation: CheckedContinuation<Data?, any Error>
    }

    nonisolated let transportKind: LoomTransportKind = .udp
    nonisolated let remoteEndpoint: LoomNetworkEndpoint
    nonisolated let identity = UUID()

    private let channel: any Channel
    private let remoteAddress: SocketAddress
    private let localEndpointValue: LoomNetworkEndpoint
    private let onCancel: @Sendable (SocketAddress, UUID) async -> Void
    private let onHardCancel: @Sendable (SocketAddress, UUID) async -> Void
    private var queuedDatagrams: [Data] = []
    private var queuedBytes = 0
    private var receiveWaiter: ReceiveWaiter?
    private var terminalError: LoomNetworkError?
    private var isCancelled = false
    private var hasIssuedHardCancel = false
    private var eventContinuations: [UUID: AsyncStream<LoomNetworkConnectionEvent>.Continuation] = [:]
    private var didStart = false

    private static let maximumQueuedBytes = 16 * 1024 * 1024
    private static let maximumQueuedDatagrams = 8_192

    init(
        channel: any Channel,
        remoteAddress: SocketAddress,
        remoteEndpoint: LoomNetworkEndpoint,
        localEndpoint: LoomNetworkEndpoint,
        onCancel: @escaping @Sendable (SocketAddress, UUID) async -> Void,
        onHardCancel: @escaping @Sendable (SocketAddress, UUID) async -> Void
    ) {
        self.channel = channel
        self.remoteAddress = remoteAddress
        self.remoteEndpoint = remoteEndpoint
        localEndpointValue = localEndpoint
        self.onCancel = onCancel
        self.onHardCancel = onHardCancel
    }

    var localEndpoint: LoomNetworkEndpoint? {
        get async { localEndpointValue }
    }

    var currentPath: LoomNetworkPath? {
        get async {
            didStart ? makeCurrentPath() : nil
        }
    }

    func start() throws {
        if let terminalError { throw terminalError }
        guard !isCancelled else {
            throw LoomNetworkError(code: .cancelled, detail: "Datagram connection cancelled.")
        }
        guard !didStart else { return }
        didStart = true
        publish(.path(makeCurrentPath()))
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard !isCancelled else {
            throw LoomNetworkError(code: .cancelled, detail: "Datagram connection cancelled.")
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(
                AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)
            ).get()
        } catch {
            let failure = LoomNIOUtilities.networkError(error)
            fail(failure)
            throw failure
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0 else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "Receive limit must be positive.")
        }
        try Task.checkCancellation()
        if !queuedDatagrams.isEmpty {
            let datagram = queuedDatagrams.removeFirst()
            queuedBytes -= datagram.count
            return try validate(datagram, maximumBytes: maximumBytes)
        }
        if let terminalError { throw terminalError }
        if isCancelled {
            throw LoomNetworkError(code: .cancelled, detail: "Datagram connection cancelled.")
        }
        guard receiveWaiter == nil else {
            throw LoomNetworkError(
                code: .invalidConfiguration,
                detail: "Concurrent datagram receives are not supported."
            )
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiveWaiter = ReceiveWaiter(
                    maximumBytes: maximumBytes,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelPendingReceive()
            }
        }
    }

    func makeEventStream() -> AsyncStream<LoomNetworkConnectionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: LoomNetworkConnectionEvent.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        eventContinuations[id] = continuation
        if didStart {
            continuation.yield(.path(makeCurrentPath()))
        }
        if let terminalError {
            continuation.yield(.failed(terminalError))
            continuation.finish()
        } else if isCancelled {
            continuation.yield(.cancelled)
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task {
                await self.removeEventContinuation(id)
            }
        }
        return stream
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        queuedDatagrams.removeAll(keepingCapacity: false)
        queuedBytes = 0
        finishWaiter(
            throwing: LoomNetworkError(code: .cancelled, detail: "Datagram connection cancelled.")
        )
        publish(.cancelled)
        finishEvents()
        await onCancel(remoteAddress, identity)
    }

    func hardCancel() async {
        guard !hasIssuedHardCancel else { return }
        hasIssuedHardCancel = true
        if !isCancelled {
            isCancelled = true
            queuedDatagrams.removeAll(keepingCapacity: false)
            queuedBytes = 0
            finishWaiter(
                throwing: LoomNetworkError(code: .cancelled, detail: "Datagram connection hard-cut.")
            )
            publish(.cancelled)
            finishEvents()
        }
        // A prior logical cancel may have removed this peer from the hub, but it cannot prove that
        // an already-submitted write stopped. The hard cut therefore still closes the shared socket.
        await onHardCancel(remoteAddress, identity)
        // Retain a direct channel fence as well: hub ownership can disappear during listener
        // cancellation, but completion still requires the shared socket itself to be closed.
        try? await channel.close().get()
    }

    func cancelFromListener() {
        guard !isCancelled else { return }
        isCancelled = true
        queuedDatagrams.removeAll(keepingCapacity: false)
        queuedBytes = 0
        finishWaiter(
            throwing: LoomNetworkError(code: .cancelled, detail: "Datagram listener cancelled.")
        )
        publish(.cancelled)
        finishEvents()
    }

    func fail(_ error: LoomNetworkError) {
        guard terminalError == nil, !isCancelled else { return }
        terminalError = error
        finishWaiter(throwing: error)
        publish(.failed(error))
        finishEvents()
    }

    func receiveInbound(_ data: Data) {
        guard terminalError == nil, !isCancelled else { return }
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            do {
                waiter.continuation.resume(returning: try validate(data, maximumBytes: waiter.maximumBytes))
            } catch {
                waiter.continuation.resume(throwing: error)
            }
            return
        }
        guard data.count <= Self.maximumQueuedBytes - queuedBytes,
              queuedDatagrams.count < Self.maximumQueuedDatagrams else {
            fail(
                LoomNetworkError(
                    code: .other,
                    detail: "Datagram receive buffering exceeded its bounded capacity."
                )
            )
            return
        }
        queuedDatagrams.append(data)
        queuedBytes += data.count
    }

    private func validate(_ data: Data, maximumBytes: Int) throws -> Data {
        guard data.count <= maximumBytes else {
            throw LoomNetworkError(
                code: .other,
                detail: "Received datagram exceeds the caller's bounded receive size."
            )
        }
        return data
    }

    private func cancelPendingReceive() {
        finishWaiter(throwing: CancellationError())
    }

    private func finishWaiter(throwing error: any Error) {
        guard let receiveWaiter else { return }
        self.receiveWaiter = nil
        receiveWaiter.continuation.resume(throwing: error)
    }

    private func makeCurrentPath() -> LoomNetworkPath {
        LoomNIOUtilities.path(
            localEndpoint: localEndpointValue,
            remoteEndpoint: remoteEndpoint
        )
    }

    private func publish(_ event: LoomNetworkConnectionEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func finishEvents() {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll(keepingCapacity: false)
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}

private final class LoomNIODatagramDemultiplexer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let hub: LoomNIODatagramHub
    private let operations = LoomNIOAsyncOperationQueue()

    init(hub: LoomNIODatagramHub) {
        self.hub = hub
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = Self.unwrapInboundIn(data)
        operations.submit {
            await self.hub.receive(envelope)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        operations.submit {
            await self.hub.fail(LoomNIOUtilities.networkError(error))
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        operations.submit {
            await self.hub.fail(
                LoomNetworkError(code: .closed, detail: "Datagram listener closed.")
            )
        }
        context.fireChannelInactive()
    }
}
