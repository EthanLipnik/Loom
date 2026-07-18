//
//  LoomNetworkFrameworkBackend.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

#if canImport(Network)
import Foundation
import LoomNetworking
import Network

package final class LoomNetworkFrameworkBackend: LoomNetworkBackend, Sendable {
    package init() {}

    package func makeConnection(
        to endpoint: LoomNetworkEndpoint,
        using transportKind: LoomNetworking.LoomTransportKind,
        configuration: LoomNetworkConnectionConfiguration
    ) throws -> any LoomNetworkConnection {
        guard configuration.requiredInterface == nil else {
            throw LoomNetworkError(
                code: .unsupported,
                detail: "A native Network.framework interface handle is required for exact interface binding."
            )
        }
        guard let nativeEndpoint = endpoint.nwEndpoint else {
            throw LoomNetworkError(
                code: .unsupported,
                detail: "Endpoint cannot be represented by Network.framework without losing interface scope."
            )
        }
        return try makeNativeConnection(
            to: nativeEndpoint,
            using: LoomTransportKind(transportKind),
            enablePeerToPeer: configuration.enablePeerToPeer,
            requiredInterface: nil,
            requiredInterfaceType: configuration.requiredInterfaceType?.nwInterfaceType,
            requiredLocalPort: configuration.requiredLocalPort,
            datagramServiceClass: try nativeServiceClass(configuration.datagramServiceClass)
        )
    }

    package func makeListener(
        using transportKind: LoomNetworking.LoomTransportKind,
        configuration: LoomNetworkListenerConfiguration
    ) throws -> any LoomNetworkListener {
        guard transportKind != .quic else {
            throw LoomNetworkError(code: .unsupported, detail: "QUIC transport has been removed.")
        }
        return LoomNetworkFrameworkListener(
            transportKind: transportKind,
            enablePeerToPeer: configuration.enablePeerToPeer,
            datagramServiceClass: try nativeServiceClass(configuration.datagramServiceClass)
        )
    }

    package func makeNativeConnection(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        enablePeerToPeer: Bool,
        requiredInterface: NWInterface?,
        requiredInterfaceType: NWInterface.InterfaceType?,
        requiredLocalPort: UInt16?,
        datagramServiceClass: NWParameters.ServiceClass
    ) throws -> LoomNetworkFrameworkConnection {
        guard let nativeTransportKind = LoomNWConnectionTransportKind(transportKind) else {
            throw LoomNetworkError(code: .unsupported, detail: "QUIC transport has been removed.")
        }
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: nativeTransportKind,
            enablePeerToPeer: enablePeerToPeer,
            requiredInterface: requiredInterface,
            requiredInterfaceType: requiredInterfaceType,
            udpServiceClass: datagramServiceClass
        )
        if let requiredLocalPort, let port = NWEndpoint.Port(rawValue: requiredLocalPort) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: port)
            parameters.allowLocalEndpointReuse = true
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        return LoomNetworkFrameworkConnection(
            connection: connection,
            transportKind: transportKind.networkTransportKind,
            remoteEndpoint: LoomNetworkEndpoint(endpoint)
        )
    }

    private func nativeServiceClass(
        _ serviceClass: LoomNetworkServiceClass
    ) throws -> NWParameters.ServiceClass {
        guard let native = serviceClass.nwServiceClass else {
            throw LoomNetworkError(
                code: .unsupported,
                detail: "Network.framework does not recognize service class \(serviceClass.rawValue)."
            )
        }
        return native
    }
}

package enum LoomNetworkFrameworkDatagramReceiveStrategy: String, Sendable, CaseIterable {
    case direct
    case actorIsolated = "actor_isolated"
}

private struct LoomNativeDatagramReceiveDriver: LoomNetworkFrameworkDatagramReceiveDriver {
    let connection: NWConnection

    func receiveMessage(
        completion: @escaping @Sendable (LoomNetworkFrameworkDatagramReceiveEvent) -> Void
    ) {
        connection.receiveMessage { data, _, isComplete, error in
            if let error {
                completion(.failed(LoomNetworkFrameworkConnection.networkError(error)))
            } else if let data {
                completion(.datagram(data))
            } else if isComplete {
                completion(.closed)
            } else {
                completion(.failed(LoomNetworkError(
                    code: .other,
                    detail: "Connection produced no datagram result."
                )))
            }
        }
    }
}

private struct LoomNativeStreamReceiveDriver: LoomNetworkFrameworkStreamReceiveDriver {
    let connection: NWConnection

    func receiveStreamChunk(
        maximumBytes: Int,
        completion: @escaping @Sendable (LoomNetworkFrameworkStreamReceiveEvent) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumBytes
        ) { data, _, isComplete, error in
            if let error {
                completion(.failed(LoomNetworkFrameworkConnection.networkError(error)))
            } else if let data, !data.isEmpty {
                completion(.chunk(data, endOfStream: isComplete))
            } else if isComplete {
                completion(.closed)
            } else {
                completion(.failed(LoomNetworkError(
                    code: .other,
                    detail: "Connection produced no stream receive result."
                )))
            }
        }
    }
}

private struct LoomNetworkFrameworkDatagramReceiveResult: Sendable {
    let data: Data?
    let callbackAt: TimeInterval
}

package actor LoomNetworkFrameworkConnection: LoomNetworkConnection, LoomConcurrentQueuedSendConnection {
    nonisolated package let transportKind: LoomNetworking.LoomTransportKind
    nonisolated package let remoteEndpoint: LoomNetworkEndpoint
    nonisolated package let nativeConnection: NWConnection
    nonisolated package let datagramReceiveStrategy: LoomNetworkFrameworkDatagramReceiveStrategy
    nonisolated private let datagramReceiveDiagnostics: LoomNetworkFrameworkDatagramReceiveDiagnostics
    nonisolated private let datagramReceivePump: LoomNetworkFrameworkDatagramReceivePump?
    nonisolated private let streamReceivePump: LoomNetworkFrameworkStreamReceivePump?

    private var isStarting = false
    private var isReady = false
    private var terminalError: LoomNetworkError?
    private var isCancelled = false
    private var startWaiters: [CheckedContinuation<Void, any Error>] = []
    private var eventContinuations: [UUID: AsyncStream<LoomNetworkConnectionEvent>.Continuation] = [:]
    package var currentPath: LoomNetworkPath?

    package init(
        connection: NWConnection,
        transportKind: LoomNetworking.LoomTransportKind,
        remoteEndpoint: LoomNetworkEndpoint? = nil,
        datagramReceiveStrategy: LoomNetworkFrameworkDatagramReceiveStrategy = .direct
    ) {
        nativeConnection = connection
        self.transportKind = transportKind
        self.datagramReceiveStrategy = datagramReceiveStrategy
        let datagramReceiveDiagnostics = LoomNetworkFrameworkDatagramReceiveDiagnostics()
        self.datagramReceiveDiagnostics = datagramReceiveDiagnostics
        if transportKind == .udp, datagramReceiveStrategy == .direct {
            datagramReceivePump = LoomNetworkFrameworkDatagramReceivePump(
                driver: LoomNativeDatagramReceiveDriver(connection: connection),
                diagnostics: datagramReceiveDiagnostics,
                strategy: datagramReceiveStrategy
            )
        } else {
            datagramReceivePump = nil
        }
        if transportKind == .tcp {
            streamReceivePump = LoomNetworkFrameworkStreamReceivePump(
                driver: LoomNativeStreamReceiveDriver(connection: connection)
            )
        } else {
            streamReceivePump = nil
        }
        self.remoteEndpoint = remoteEndpoint ??
            LoomNetworkEndpoint(connection.endpoint) ??
            .opaque(description: String(describing: connection.endpoint))
    }

    package var localEndpoint: LoomNetworkEndpoint? {
        get async {
            if let localEndpoint = currentPath?.localEndpoint {
                return localEndpoint
            }
            guard let nativeEndpoint = nativeConnection.currentPath?.localEndpoint else {
                return nil
            }
            return LoomNetworkEndpoint(nativeEndpoint)
        }
    }

    package func start() async throws {
        if isReady { return }
        if let terminalError { throw terminalError }
        if isCancelled {
            throw LoomNetworkError(code: .cancelled, detail: "Connection cancelled.")
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            startWaiters.append(continuation)
            guard !isStarting else { return }
            isStarting = true
            nativeConnection.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                Task {
                    await self.handlePath(path)
                }
            }
            nativeConnection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task {
                    await self.handleState(state)
                }
            }
            nativeConnection.start(queue: .global(qos: .userInitiated))
        }
    }

    package func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            nativeConnection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.networkError(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    package nonisolated func sendQueued(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        nativeConnection.send(content: data, completion: .contentProcessed { error in
            completion(error.map(Self.networkError))
        })
    }

    package nonisolated func receive(maximumBytes: Int) async throws -> Data? {
        if let streamReceivePump {
            return try await streamReceivePump.receive(maximumBytes: maximumBytes)
        }
        guard transportKind == .udp,
              datagramReceiveStrategy == .direct,
              let datagramReceivePump else {
            return try await receiveActorIsolated(maximumBytes: maximumBytes)
        }
        return try await datagramReceivePump.receive(maximumBytes: maximumBytes)
    }

    package func makeEventStream() -> AsyncStream<LoomNetworkConnectionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: LoomNetworkConnectionEvent.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        eventContinuations[id] = continuation
        if let currentPath {
            continuation.yield(.path(currentPath))
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

    package func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let error = LoomNetworkError(code: .cancelled, detail: "Connection cancelled.")
        datagramReceivePump?.cancel(with: error)
        streamReceivePump?.cancel(with: error)
        nativeConnection.cancel()
        resumeStartWaiters(throwing: error)
        publish(.cancelled)
        finishEvents()
    }

    private func receiveActorIsolated(maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0 else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "Receive limit must be positive.")
        }
        try Task.checkCancellation()
        switch transportKind {
        case .tcp:
            throw LoomNetworkError(
                code: .invalidConfiguration,
                detail: "TCP receive pump is unavailable."
            )
        case .udp:
            let result = try await Self.receiveDatagram(
                over: nativeConnection,
                maximumBytes: maximumBytes,
                diagnostics: datagramReceiveDiagnostics
            )
            datagramReceiveDiagnostics.recordConsumerResume(
                afterCallbackAt: result.callbackAt,
                strategy: datagramReceiveStrategy
            )
            return result.data
        case .quic:
            throw LoomNetworkError(code: .unsupported, detail: "QUIC transport has been removed.")
        }
    }

    private nonisolated static func receiveDatagram(
        over connection: NWConnection,
        maximumBytes: Int,
        diagnostics: LoomNetworkFrameworkDatagramReceiveDiagnostics
    ) async throws -> LoomNetworkFrameworkDatagramReceiveResult {
        diagnostics.recordRegistration()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<LoomNetworkFrameworkDatagramReceiveResult, any Error>) in
            connection.receiveMessage { data, _, isComplete, error in
                let callbackAt = ProcessInfo.processInfo.systemUptime
                diagnostics.recordCallback(at: callbackAt)
                if let error {
                    continuation.resume(throwing: Self.networkError(error))
                } else if let data, data.count <= maximumBytes {
                    continuation.resume(returning: LoomNetworkFrameworkDatagramReceiveResult(
                        data: data,
                        callbackAt: callbackAt
                    ))
                } else if let data {
                    continuation.resume(
                        throwing: LoomNetworkError(
                            code: .other,
                            detail: "Received datagram exceeds the caller's bounded receive size (\(data.count) bytes)."
                        )
                    )
                } else if isComplete {
                    continuation.resume(returning: LoomNetworkFrameworkDatagramReceiveResult(
                        data: nil,
                        callbackAt: callbackAt
                    ))
                } else {
                    continuation.resume(
                        throwing: LoomNetworkError(code: .other, detail: "Connection produced no datagram result.")
                    )
                }
            }
        }
    }

    private func handlePath(_ path: NWPath) {
        let snapshot = LoomNetworkPath(path)
        currentPath = snapshot
        publish(.path(snapshot))
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            isStarting = false
            datagramReceivePump?.start()
            streamReceivePump?.start()
            if let path = nativeConnection.currentPath {
                handlePath(path)
            }
            resumeStartWaiters()
        case let .failed(error):
            fail(Self.networkError(error))
        case .cancelled:
            guard !isCancelled else { return }
            isCancelled = true
            let error = LoomNetworkError(code: .cancelled, detail: "Connection cancelled.")
            datagramReceivePump?.cancel(with: error)
            streamReceivePump?.cancel(with: error)
            resumeStartWaiters(throwing: error)
            publish(.cancelled)
            finishEvents()
        case let .waiting(error):
            guard Self.shouldFailAfterWaiting(error) else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await self.failStartIfPending(Self.networkError(error))
            }
        default:
            break
        }
    }

    private func failStartIfPending(_ error: LoomNetworkError) {
        guard !isReady, isStarting else { return }
        fail(error)
    }

    private func fail(_ error: LoomNetworkError) {
        guard terminalError == nil, !isCancelled else { return }
        terminalError = error
        isStarting = false
        datagramReceivePump?.finish(with: error)
        streamReceivePump?.finish(with: error)
        resumeStartWaiters(throwing: error)
        publish(.failed(error))
        finishEvents()
    }

    private func resumeStartWaiters(throwing error: (any Error)? = nil) {
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
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

    fileprivate nonisolated static func networkError(_ error: NWError) -> LoomNetworkError {
        let code: LoomNetworkErrorCode
        switch error {
        case let .posix(posixCode):
            switch posixCode {
            case .ECANCELED:
                code = .cancelled
            case .ECONNREFUSED:
                code = .connectionRefused
            case .ENETDOWN:
                code = .networkDown
            case .EHOSTUNREACH, .ENETUNREACH:
                code = .unreachable
            case .ETIMEDOUT:
                code = .timedOut
            case .ECONNRESET, .ENOTCONN, .EPIPE:
                code = .closed
            default:
                code = .other
            }
        default:
            code = .other
        }
        return LoomNetworkError(code: code, detail: error.localizedDescription)
    }

    private nonisolated static func shouldFailAfterWaiting(_ error: NWError) -> Bool {
        guard case let .posix(code) = error else { return false }
        return ([.ENETDOWN, .EHOSTUNREACH, .ENETUNREACH, .ENOTCONN] as [POSIXErrorCode])
            .contains(code)
    }
}

private actor LoomNetworkFrameworkListener: LoomNetworkListener {
    nonisolated let transportKind: LoomNetworking.LoomTransportKind

    private let enablePeerToPeer: Bool
    private let datagramServiceClass: NWParameters.ServiceClass
    private let connectionStream: AsyncStream<any LoomNetworkConnection>
    private let connectionContinuation: AsyncStream<any LoomNetworkConnection>.Continuation
    private var listener: NWListener?

    init(
        transportKind: LoomNetworking.LoomTransportKind,
        enablePeerToPeer: Bool,
        datagramServiceClass: NWParameters.ServiceClass
    ) {
        self.transportKind = transportKind
        self.enablePeerToPeer = enablePeerToPeer
        self.datagramServiceClass = datagramServiceClass
        let (stream, continuation) = AsyncStream.makeStream(
            of: (any LoomNetworkConnection).self,
            bufferingPolicy: .bufferingNewest(64)
        )
        connectionStream = stream
        connectionContinuation = continuation
    }

    func start(port: UInt16) async throws -> UInt16 {
        guard listener == nil,
              let nativeTransportKind = LoomNWConnectionTransportKind(
                  LoomTransportKind(transportKind)
              ) else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "Listener cannot be started.")
        }
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: nativeTransportKind,
            enablePeerToPeer: enablePeerToPeer,
            udpServiceClass: datagramServiceClass
        )
        parameters.allowLocalEndpointReuse = true
        let actualPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: actualPort)
        self.listener = listener
        listener.newConnectionHandler = { [connectionContinuation, transportKind] nativeConnection in
            let connection = LoomNetworkFrameworkConnection(
                connection: nativeConnection,
                transportKind: transportKind
            )
            switch connectionContinuation.yield(connection) {
            case .enqueued:
                break
            case let .dropped(droppedConnection):
                Task { await droppedConnection.cancel() }
            case .terminated:
                Task { await connection.cancel() }
            @unknown default:
                Task { await connection.cancel() }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<UInt16>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        box.resume(returning: port)
                    }
                case let .failed(error):
                    box.resume(throwing: LoomNetworkFrameworkConnection.networkError(error))
                case .cancelled:
                    box.resume(
                        throwing: LoomNetworkError(code: .cancelled, detail: "Listener cancelled.")
                    )
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func makeConnectionStream() -> AsyncStream<any LoomNetworkConnection> {
        connectionStream
    }

    func cancel() {
        listener?.cancel()
        listener = nil
        connectionContinuation.finish()
    }
}

package enum LoomTransportParametersFactory {
    package static func makeParameters(
        for transportKind: LoomNWConnectionTransportKind,
        enablePeerToPeer: Bool,
        requiredInterface: NWInterface? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        udpServiceClass: NWParameters.ServiceClass = .interactiveVideo
    ) throws -> NWParameters {
        let parameters: NWParameters
        switch transportKind {
        case .tcp:
            parameters = NWParameters.tcp
            parameters.includePeerToPeer = enablePeerToPeer
            if #available(iOS 26, macOS 26, visionOS 26, *) {
                parameters.allowUltraConstrainedPaths = enablePeerToPeer
            }
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveInterval = 5
            }
        case .udp:
            parameters = NWParameters.udp
            parameters.includePeerToPeer = enablePeerToPeer
            if #available(iOS 26, macOS 26, visionOS 26, *) {
                parameters.allowUltraConstrainedPaths = enablePeerToPeer
            }
            parameters.serviceClass = udpServiceClass
        }
        if let requiredInterface {
            parameters.requiredInterface = requiredInterface
        } else if let requiredInterfaceType {
            parameters.requiredInterfaceType = requiredInterfaceType
        }
        return parameters
    }
}

package extension LoomFramedConnection {
    init(
        connection: NWConnection,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        incompleteFrameTimeout: Duration = .seconds(60)
    ) {
        self.init(
            connection: LoomNetworkFrameworkConnection(
                connection: connection,
                transportKind: .tcp
            ),
            retainedCapacityBudget: retainedCapacityBudget,
            incompleteFrameTimeout: incompleteFrameTimeout
        )
    }

    nonisolated static func shouldFailAfterWaiting(_ error: NWError) -> Bool {
        guard case let .posix(code) = error else { return false }
        return ([.ENETDOWN, .EHOSTUNREACH, .ENETUNREACH, .ENOTCONN] as [POSIXErrorCode])
            .contains(code)
    }
}

package extension LoomReliableChannel {
    init(
        connection: NWConnection,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        maximumPendingReliablePackets: Int = 8_192,
        maximumPendingReliableBytes: Int = 16 * 1024 * 1024,
        datagramReceiveStrategy: LoomNetworkFrameworkDatagramReceiveStrategy = .direct
    ) {
        self.init(
            connection: LoomNetworkFrameworkConnection(
                connection: connection,
                transportKind: .udp,
                datagramReceiveStrategy: datagramReceiveStrategy
            ),
            retainedCapacityBudget: retainedCapacityBudget,
            maximumPendingReliablePackets: maximumPendingReliablePackets,
            maximumPendingReliableBytes: maximumPendingReliableBytes
        )
    }
}

#endif
