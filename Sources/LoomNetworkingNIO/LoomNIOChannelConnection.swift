//
//  LoomNIOChannelConnection.swift
//  LoomNetworkingNIO
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking
import NIOCore
import NIOPosix

actor LoomNIOChannelConnection: LoomNetworkConnection {
    private enum TerminalState {
        case orderlyClose
        case cancelled
        case failed(LoomNetworkError)
    }

    private struct ReceiveWaiter {
        let maximumBytes: Int
        let continuation: CheckedContinuation<Data?, any Error>
    }

    nonisolated let transportKind: LoomTransportKind
    nonisolated let remoteEndpoint: LoomNetworkEndpoint

    private let eventLoopGroup: any EventLoopGroup
    private let requiredLocalPort: UInt16?
    private var channel: (any Channel)?
    private var startTask: Task<any Channel, any Error>?
    private var localEndpointValue: LoomNetworkEndpoint?
    private var resolvedRemoteEndpoint: LoomNetworkEndpoint
    private var queuedReads: [Data] = []
    private var queuedReadBytes = 0
    private var receiveWaiter: ReceiveWaiter?
    private var terminalState: TerminalState?
    private var eventContinuations: [UUID: AsyncStream<LoomNetworkConnectionEvent>.Continuation] = [:]
    private var didPublishInitialPath = false

    private static let maximumQueuedReadBytes = 32 * 1024 * 1024
    private static let maximumQueuedReadCount = 8_192

    init(
        transportKind: LoomTransportKind,
        remoteEndpoint: LoomNetworkEndpoint,
        eventLoopGroup: any EventLoopGroup,
        requiredLocalPort: UInt16?
    ) {
        self.transportKind = transportKind
        self.remoteEndpoint = remoteEndpoint
        self.eventLoopGroup = eventLoopGroup
        self.requiredLocalPort = requiredLocalPort
        resolvedRemoteEndpoint = remoteEndpoint
    }

    init(
        acceptedChannel channel: any Channel,
        transportKind: LoomTransportKind,
        remoteEndpoint: LoomNetworkEndpoint,
        localEndpoint: LoomNetworkEndpoint?
    ) {
        self.transportKind = transportKind
        self.remoteEndpoint = remoteEndpoint
        eventLoopGroup = channel.eventLoop
        requiredLocalPort = nil
        self.channel = channel
        localEndpointValue = localEndpoint
        resolvedRemoteEndpoint = remoteEndpoint
    }

    var localEndpoint: LoomNetworkEndpoint? {
        get async {
            localEndpointValue
        }
    }

    var currentPath: LoomNetworkPath? {
        get async {
            didPublishInitialPath ? makeCurrentPath() : nil
        }
    }

    func start() async throws {
        if let terminalState {
            try ensureStartable(terminalState)
            return
        }
        if channel == nil {
            let task: Task<any Channel, any Error>
            if let startTask {
                task = startTask
            } else {
                let newTask = Task<any Channel, any Error> { [self] in
                    try await makeChannel()
                }
                startTask = newTask
                task = newTask
            }
            do {
                let startedChannel = try await task.value
                startTask = nil
                if let terminalError = terminalError() {
                    try? await startedChannel.close().get()
                    throw terminalError
                }
                channel = startedChannel
            } catch {
                startTask = nil
                if let terminalError = terminalError() {
                    throw terminalError
                }
                let failure = LoomNIOUtilities.networkError(error)
                finish(.failed(failure))
                throw failure
            }
        }
        if let channel {
            localEndpointValue = LoomNIOUtilities.endpoint(for: channel.localAddress)
            resolvedRemoteEndpoint = LoomNIOUtilities.endpoint(for: channel.remoteAddress) ?? remoteEndpoint
        }
        publishInitialPathIfNeeded()
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let channel, terminalState == nil else {
            throw terminalError() ?? LoomNetworkError(code: .closed, detail: "Connection is not ready.")
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            let failure = LoomNIOUtilities.networkError(error)
            finish(.failed(failure))
            throw failure
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0 else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "Receive limit must be positive.")
        }
        try Task.checkCancellation()
        if !queuedReads.isEmpty {
            return try consumeFirstQueuedRead(maximumBytes: maximumBytes)
        }
        if let terminalState {
            return try terminalReceiveResult(terminalState)
        }
        guard receiveWaiter == nil else {
            throw LoomNetworkError(
                code: .invalidConfiguration,
                detail: "Concurrent receives on one Loom network connection are not supported."
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
        if didPublishInitialPath {
            continuation.yield(.path(makeCurrentPath()))
        }
        if let terminalState {
            yield(terminalState, to: continuation)
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
        queuedReads.removeAll(keepingCapacity: false)
        queuedReadBytes = 0
        if terminalState == nil {
            finish(.cancelled)
        }
        startTask?.cancel()
        startTask = nil
        if let channel {
            try? await channel.close().get()
        }
    }

    func receiveInbound(_ data: Data) async {
        guard terminalState == nil else { return }
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            do {
                waiter.continuation.resume(returning: try consume(data, maximumBytes: waiter.maximumBytes))
            } catch {
                waiter.continuation.resume(throwing: error)
            }
            return
        }
        guard data.count <= Self.maximumQueuedReadBytes - queuedReadBytes,
              queuedReads.count < Self.maximumQueuedReadCount else {
            let failure = LoomNetworkError(
                code: .other,
                detail: "SwiftNIO receive buffering exceeded its bounded capacity."
            )
            finish(.failed(failure))
            if let channel {
                try? await channel.close().get()
            }
            return
        }
        queuedReads.append(data)
        queuedReadBytes += data.count
    }

    func channelClosed(error: (any Error)? = nil) {
        guard terminalState == nil else { return }
        if let error {
            finish(.failed(LoomNIOUtilities.networkError(error)))
        } else {
            finish(.orderlyClose)
        }
    }

    private func makeChannel() async throws -> any Channel {
        let remoteAddress = try LoomNIOUtilities.socketAddress(for: remoteEndpoint)
        switch transportKind {
        case .tcp:
            var bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelOption(.socketOption(.tcp_nodelay), value: 1)
                .channelOption(.socketOption(.so_keepalive), value: 1)
                .channelInitializer { [self] channel in
                    channel.pipeline.addHandler(LoomNIOStreamChannelHandler(connection: self))
                }
            if let requiredLocalPort {
                bootstrap = bootstrap.bind(
                    to: try LoomNIOUtilities.wildcardAddress(
                        matching: remoteAddress,
                        port: requiredLocalPort
                    )
                )
            }
            return try await bootstrap.connect(to: remoteAddress).get()
        case .udp:
            let localAddress = try LoomNIOUtilities.wildcardAddress(
                matching: remoteAddress,
                port: requiredLocalPort ?? 0
            )
            let bootstrap = DatagramBootstrap(group: eventLoopGroup)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { [self] channel in
                    channel.pipeline.addHandler(
                        LoomNIOConnectedDatagramHandler(
                            connection: self,
                            remoteAddress: remoteAddress
                        )
                    )
                }
            let channel = try await bootstrap.bind(to: localAddress).get()
            do {
                try await channel.connect(to: remoteAddress).get()
                return channel
            } catch {
                try? await channel.close().get()
                throw error
            }
        case .quic:
            throw LoomNetworkError(code: .unsupported, detail: "QUIC is unavailable.")
        }
    }

    private func consumeFirstQueuedRead(maximumBytes: Int) throws -> Data {
        let data = queuedReads.removeFirst()
        queuedReadBytes -= data.count
        return try consume(data, maximumBytes: maximumBytes)
    }

    private func consume(_ data: Data, maximumBytes: Int) throws -> Data {
        guard data.count > maximumBytes else { return data }
        guard transportKind == .tcp else {
            throw LoomNetworkError(
                code: .other,
                detail: "Received datagram exceeds the caller's bounded receive size."
            )
        }
        let prefix = Data(data.prefix(maximumBytes))
        let remainder = Data(data.dropFirst(maximumBytes))
        queuedReads.insert(remainder, at: 0)
        queuedReadBytes += remainder.count
        return prefix
    }

    private func cancelPendingReceive() {
        guard let receiveWaiter else { return }
        self.receiveWaiter = nil
        receiveWaiter.continuation.resume(throwing: CancellationError())
    }

    private func publishInitialPathIfNeeded() {
        guard !didPublishInitialPath else { return }
        didPublishInitialPath = true
        publish(.path(makeCurrentPath()))
    }

    private func makeCurrentPath() -> LoomNetworkPath {
        LoomNIOUtilities.path(
            localEndpoint: localEndpointValue,
            remoteEndpoint: resolvedRemoteEndpoint
        )
    }

    private func finish(_ state: TerminalState) {
        guard terminalState == nil else { return }
        terminalState = state
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            switch state {
            case .orderlyClose:
                waiter.continuation.resume(returning: nil)
            case .cancelled:
                waiter.continuation.resume(
                    throwing: LoomNetworkError(code: .cancelled, detail: "Connection cancelled.")
                )
            case let .failed(error):
                waiter.continuation.resume(throwing: error)
            }
        }
        for continuation in eventContinuations.values {
            yield(state, to: continuation)
            continuation.finish()
        }
        eventContinuations.removeAll(keepingCapacity: false)
    }

    private func terminalError() -> (any Error)? {
        guard let terminalState else { return nil }
        switch terminalState {
        case .orderlyClose:
            return LoomNetworkError(code: .closed, detail: "Connection closed by peer.")
        case .cancelled:
            return LoomNetworkError(code: .cancelled, detail: "Connection cancelled.")
        case let .failed(error):
            return error
        }
    }

    private func terminalReceiveResult(_ state: TerminalState) throws -> Data? {
        switch state {
        case .orderlyClose:
            return nil
        case .cancelled:
            throw LoomNetworkError(code: .cancelled, detail: "Connection cancelled.")
        case let .failed(error):
            throw error
        }
    }

    private func ensureStartable(_ state: TerminalState) throws {
        switch state {
        case .orderlyClose:
            throw LoomNetworkError(code: .closed, detail: "Connection closed by peer.")
        case .cancelled:
            throw LoomNetworkError(code: .cancelled, detail: "Connection cancelled.")
        case let .failed(error):
            throw error
        }
    }

    private func publish(_ event: LoomNetworkConnectionEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func yield(
        _ state: TerminalState,
        to continuation: AsyncStream<LoomNetworkConnectionEvent>.Continuation
    ) {
        switch state {
        case .orderlyClose:
            continuation.yield(
                .failed(LoomNetworkError(code: .closed, detail: "Connection closed by peer."))
            )
        case .cancelled:
            continuation.yield(.cancelled)
        case let .failed(error):
            continuation.yield(.failed(error))
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}

final class LoomNIOStreamChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connection: LoomNIOChannelConnection
    private let operations = LoomNIOAsyncOperationQueue()

    init(connection: LoomNIOChannelConnection) {
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        let bytes = Data(buffer.readableBytesView)
        operations.submit {
            await self.connection.receiveInbound(bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        operations.submit {
            await self.connection.channelClosed()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        operations.submit {
            await self.connection.channelClosed(error: error)
        }
        context.close(promise: nil)
    }
}

private final class LoomNIOConnectedDatagramHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let connection: LoomNIOChannelConnection
    private let remoteAddress: SocketAddress
    private let operations = LoomNIOAsyncOperationQueue()

    init(connection: LoomNIOChannelConnection, remoteAddress: SocketAddress) {
        self.connection = connection
        self.remoteAddress = remoteAddress
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = Self.unwrapInboundIn(data)
        let bytes = Data(envelope.data.readableBytesView)
        operations.submit {
            await self.connection.receiveInbound(bytes)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = Self.unwrapOutboundIn(data)
        context.write(
            Self.wrapOutboundOut(AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)),
            promise: promise
        )
    }

    func channelInactive(context: ChannelHandlerContext) {
        operations.submit {
            await self.connection.channelClosed()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        operations.submit {
            await self.connection.channelClosed(error: error)
        }
        context.close(promise: nil)
    }
}

final class LoomNIOAsyncOperationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        let task = Task {
            if let previous {
                await previous.value
            }
            await operation()
        }
        tail = task
        lock.unlock()
    }
}
