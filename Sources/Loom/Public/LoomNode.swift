//
//  LoomNode.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
#if canImport(Network)
import Network
#else
import LoomNetworkingNIO
#endif
import Observation

#if canImport(Network)
/// Direct transport kinds backed by Network.framework compatibility adapters.
package enum LoomNWConnectionTransportKind: String, Codable, CaseIterable, Sendable {
    case tcp
    case udp

    package init?(_ transportKind: LoomTransportKind) {
        switch transportKind {
        case .tcp:
            self = .tcp
        case .udp:
            self = .udp
        case .quic:
            return nil
        }
    }

    package var transportKind: LoomTransportKind {
        switch self {
        case .tcp:
            .tcp
        case .udp:
            .udp
        }
    }
}

/// A Loom direct connection.
public enum LoomConnection: Sendable {
    case tcp(NWConnection)
    case udp(NWConnection)

    package init(connection: NWConnection, transportKind: LoomNWConnectionTransportKind) {
        switch transportKind {
        case .tcp:
            self = .tcp(connection)
        case .udp:
            self = .udp(connection)
        }
    }

    public var transportKind: LoomTransportKind {
        switch self {
        case .tcp:
            .tcp
        case .udp:
            .udp
        }
    }

    public var endpoint: NWEndpoint? {
        switch self {
        case let .tcp(connection), let .udp(connection):
            connection.endpoint
        }
    }

    /// Backend-independent endpoint for this connection.
    public var backendEndpoint: LoomNetworkEndpoint {
        switch self {
        case let .tcp(connection), let .udp(connection):
            LoomNetworkEndpoint(connection.endpoint) ??
                .opaque(description: String(describing: connection.endpoint))
        }
    }

    package var backingNWConnection: NWConnection? {
        switch self {
        case let .tcp(connection), let .udp(connection):
            connection
        }
    }

    package var backendConnection: any LoomNetworkConnection {
        switch self {
        case let .tcp(connection):
            LoomNetworkFrameworkConnection(
                connection: connection,
                transportKind: .tcp
            )
        case let .udp(connection):
            LoomNetworkFrameworkConnection(
                connection: connection,
                transportKind: .udp
            )
        }
    }

    package func cancel() async {
        await backendConnection.cancel()
    }
}
#endif

@Observable
@MainActor
public final class LoomNode {
    private struct BonjourAdvertisingContext {
        let serviceName: String
        let advertisement: LoomPeerAdvertisement
        let onConnection: LoomDirectConnectionHandler
    }

    public var configuration: LoomNetworkConfiguration
    public var identityManager: LoomIdentityManager?
    public weak var trustProvider: (any LoomTrustProvider)?

    public private(set) var discovery: LoomDiscovery?
    public private(set) var advertisingDiagnostics = LoomAdvertisingDiagnostics()

    private var advertiser: BonjourAdvertiser?
    private var advertisingServiceName: String?
    private var publishedAdvertisement: LoomPeerAdvertisement?
    private var directListeners: [LoomTransportKind: any LoomDirectTransportListener] = [:]
    private var directListenerPorts: [LoomTransportKind: UInt16] = [:]
#if canImport(Network)
    private var overlayProbeServer: LoomOverlayProbeServer?
#endif
    private var bonjourAdvertisingContext: BonjourAdvertisingContext?
    private var bonjourAdvertisingGeneration = UUID()
    private var bonjourAdvertisingRecoveryTask: Task<Void, Never>?
    private var bonjourAdvertisingRecoveryAttempt = 0
    private let preauthenticationWorkLimiter: LoomOutstandingOperationLimiter
    private let preauthenticationAdmission: LoomPreauthenticationAdmissionController
    private let activeAuthenticatedSessionAdmission: LoomPreauthenticationAdmissionController
    private let incomingRetainedCapacityBudget: LoomIncomingRetainedCapacityBudget
    private var authenticatedAdvertisingGeneration = UUID()
    private var isStartingAuthenticatedAdvertising = false
    private let networkBackend: any LoomNetworkBackend

    nonisolated private static let minimumBonjourAdvertisingRecoveryDelay: Duration = .seconds(1)

    public init(
        configuration: LoomNetworkConfiguration = .default,
        identityManager: LoomIdentityManager? = LoomIdentityManager.shared,
        trustProvider: (any LoomTrustProvider)? = nil
    ) {
        self.configuration = configuration
        self.identityManager = identityManager
        self.trustProvider = trustProvider
#if canImport(Network)
        networkBackend = LoomNetworkFrameworkBackend()
#else
        networkBackend = LoomNIONetworkBackend()
#endif
        preauthenticationWorkLimiter = LoomOutstandingOperationLimiter(
            maximumConcurrentOperations: configuration.maxPendingAuthenticatedSessions
        )
        preauthenticationAdmission = LoomPreauthenticationAdmissionController(
            maxConcurrentConnections: configuration.maxPendingAuthenticatedSessions
        )
        activeAuthenticatedSessionAdmission = LoomPreauthenticationAdmissionController(
            maxConcurrentConnections: configuration.maximumActiveAuthenticatedSessions
        )
        incomingRetainedCapacityBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: configuration.maximumBufferedIncomingBytesPerNode,
            maximumPayloadCount: configuration.maximumBufferedIncomingPayloadsPerNode,
            maximumBatchCount: configuration.maximumBufferedIncomingPayloadsPerNode
        )
    }

    /// Creates a node with an explicitly supplied backend-independent network implementation.
    public init(
        configuration: LoomNetworkConfiguration,
        identityManager: LoomIdentityManager?,
        trustProvider: (any LoomTrustProvider)?,
        networkBackend: any LoomNetworkBackend
    ) {
        self.configuration = configuration
        self.identityManager = identityManager
        self.trustProvider = trustProvider
        self.networkBackend = networkBackend
        preauthenticationWorkLimiter = LoomOutstandingOperationLimiter(
            maximumConcurrentOperations: configuration.maxPendingAuthenticatedSessions
        )
        preauthenticationAdmission = LoomPreauthenticationAdmissionController(
            maxConcurrentConnections: configuration.maxPendingAuthenticatedSessions
        )
        activeAuthenticatedSessionAdmission = LoomPreauthenticationAdmissionController(
            maxConcurrentConnections: configuration.maximumActiveAuthenticatedSessions
        )
        incomingRetainedCapacityBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: configuration.maximumBufferedIncomingBytesPerNode,
            maximumPayloadCount: configuration.maximumBufferedIncomingPayloadsPerNode,
            maximumBatchCount: configuration.maximumBufferedIncomingPayloadsPerNode
        )
    }

    public func makeDiscovery(localDeviceID: UUID? = nil) -> LoomDiscovery {
        if let discovery {
            discovery.enableBonjour = configuration.enableBonjour
            discovery.enablePeerToPeer = configuration.enablePeerToPeer
            discovery.directConnectionPolicy = configuration.directConnectionPolicy
            if let localDeviceID {
                discovery.localDeviceID = localDeviceID
            }
            return discovery
        }

        let discovery = LoomDiscovery(
            serviceType: configuration.serviceType,
            enableBonjour: configuration.enableBonjour,
            enablePeerToPeer: configuration.enablePeerToPeer,
            directConnectionPolicy: configuration.directConnectionPolicy,
            localDeviceID: localDeviceID
        )
        self.discovery = discovery
        return discovery
    }

    private func startAdvertising(
        serviceName: String,
        advertisement: LoomPeerAdvertisement,
        authenticatedGeneration: UUID,
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16 {
        advertisingServiceName = serviceName
        bonjourAdvertisingRecoveryTask?.cancel()

        guard configuration.enableBonjour else {
            let directListener = try makeDirectTransportListener(for: .tcp)
            directListeners[.tcp] = directListener
            advertisingDiagnostics = advertisingDiagnostics.updating(
                state: .starting,
                serviceName: serviceName,
                directListenerPorts: directListenerPorts,
                bonjourRecoveryAttempt: 0
            )
            let port: UInt16
            do {
                port = try await directListener.start(
                    port: configuration.controlPort,
                    onConnection: onConnection
                )
                try validateAuthenticatedAdvertisingGeneration(authenticatedGeneration)
            } catch {
                if isCurrentDirectListener(directListener, for: .tcp) {
                    directListeners.removeValue(forKey: .tcp)
                }
                await directListener.stop()
                throw error
            }
            directListenerPorts[.tcp] = port
            publishedAdvertisement = Self.advertisement(
                advertisement,
                withDirectTransportPorts: directTransportPorts(advertiserTCPPort: nil),
                serviceName: serviceName
            )
            advertisingDiagnostics = advertisingDiagnostics.updating(
                state: .advertising,
                serviceName: serviceName,
                directListenerPorts: directListenerPorts,
                bonjourRecoveryAttempt: 0
            )
            return port
        }

        bonjourAdvertisingContext = BonjourAdvertisingContext(
            serviceName: serviceName,
            advertisement: advertisement,
            onConnection: onConnection
        )
        bonjourAdvertisingRecoveryAttempt = 0
        let port = try await startBonjourAdvertising(context: bonjourAdvertisingContext)
        try validateAuthenticatedAdvertisingGeneration(authenticatedGeneration)
        return port
    }

    public func stopAdvertising() async {
        authenticatedAdvertisingGeneration = UUID()
        await stopAdvertisingResources()
    }

    private func stopAdvertisingResources() async {
        bonjourAdvertisingRecoveryTask?.cancel()
        bonjourAdvertisingRecoveryTask = nil
        bonjourAdvertisingGeneration = UUID()
        bonjourAdvertisingContext = nil
        bonjourAdvertisingRecoveryAttempt = 0
#if canImport(Network)
        let overlayProbeServer = self.overlayProbeServer
        self.overlayProbeServer = nil
#endif
        let advertiser = self.advertiser
        self.advertiser = nil
        advertisingServiceName = nil
        publishedAdvertisement = nil
        let directListeners = self.directListeners.values
        self.directListeners.removeAll()
        self.directListenerPorts.removeAll()

#if canImport(Network)
        await overlayProbeServer?.stop()
#endif
        await advertiser?.stop()
        for listener in directListeners {
            await listener.stop()
        }
        advertisingDiagnostics = LoomAdvertisingDiagnostics()
    }

    public func updateAdvertisement(_ advertisement: LoomPeerAdvertisement) async {
        // Preserve Loom-managed direct transport ports when the caller provides
        // an advertisement without them (e.g. Mirage updating metadata only).
        let bonjourPort = await advertiser?.port
        let ports = directTransportPorts(advertiserTCPPort: bonjourPort)
        let merged = Self.advertisement(
            advertisement,
            withDirectTransportPorts: ports,
            serviceName: advertisingServiceName
        )
        publishedAdvertisement = merged
        if let context = bonjourAdvertisingContext {
            bonjourAdvertisingContext = BonjourAdvertisingContext(
                serviceName: context.serviceName,
                advertisement: advertisement,
                onConnection: context.onConnection
            )
        }
        await advertiser?.updateAdvertisement(merged)
    }

#if canImport(Network)
    public func makeAuthenticatedSession(
        connection: LoomConnection,
        role: LoomSessionRole,
        remoteEndpoint: NWEndpoint? = nil
    ) -> LoomAuthenticatedSession {
        incomingRetainedCapacityBudget.updateLimits(
            maximumBytes: configuration.maximumBufferedIncomingBytesPerNode,
            maximumPayloadCount: configuration.maximumBufferedIncomingPayloadsPerNode,
            maximumBatchCount: configuration.maximumBufferedIncomingPayloadsPerNode
        )
        let session = LoomAuthenticatedSession(
            connection: connection,
            role: role,
            remoteEndpoint: remoteEndpoint,
            serviceClass: connection.transportKind == .tcp ? nil : configuration.directDatagramServiceClass,
            maximumConcurrentStreams: configuration.maximumConcurrentStreamsPerSession,
            maximumBufferedIncomingBytesPerStream: configuration.maximumBufferedIncomingBytesPerStream,
            maximumBufferedIncomingPayloadsPerStream: configuration.maximumBufferedIncomingPayloadsPerStream,
            maximumBufferedIncomingBytesPerSession: configuration.maximumBufferedIncomingBytesPerSession,
            maximumBufferedIncomingPayloadsPerSession: configuration.maximumBufferedIncomingPayloadsPerSession
        )
        session.setParentIncomingRetainedCapacityBudget(incomingRetainedCapacityBudget)
        return session
    }

    public func makeConnection(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        enablePeerToPeer: Bool? = nil,
        requiredInterface: NWInterface? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        requiredLocalPort: UInt16? = nil
    ) throws -> LoomConnection {
        guard transportKind != .quic else {
            throw LoomError.protocolError("QUIC transport has been removed.")
        }
        let backendConnection = try LoomConnectionFactory.makeBackendConnection(
            to: endpoint,
            using: transportKind,
            configuration: configuration,
            backend: networkBackend,
            enablePeerToPeer: enablePeerToPeer ?? configuration.enablePeerToPeer,
            requiredInterface: requiredInterface,
            requiredInterfaceType: requiredInterfaceType,
            requiredLocalPort: requiredLocalPort
        )
        guard let nativeConnection = backendConnection as? LoomNetworkFrameworkConnection,
              let nativeTransportKind = LoomNWConnectionTransportKind(transportKind) else {
            throw LoomNetworkError(
                code: .unsupported,
                detail: "Use makeNetworkConnection(to:using:configuration:) with a portable network backend."
            )
        }
        return LoomConnection(
            connection: nativeConnection.nativeConnection,
            transportKind: nativeTransportKind
        )
    }
#endif

    /// Creates a backend-independent direct connection.
    public func makeNetworkConnection(
        to endpoint: LoomNetworkEndpoint,
        using transportKind: LoomTransportKind,
        configuration requestedConfiguration: LoomNetworkConnectionConfiguration? = nil
    ) throws -> any LoomNetworkConnection {
        let resolvedConfiguration = requestedConfiguration ?? LoomNetworkConnectionConfiguration(
            enablePeerToPeer: configuration.enablePeerToPeer,
            datagramServiceClass: configuration.backendDirectDatagramServiceClass
        )
        return try networkBackend.makeConnection(
            to: endpoint,
            using: transportKind.networkTransportKind,
            configuration: resolvedConfiguration
        )
    }

#if canImport(Network)
    public func connect(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        hello: LoomSessionHelloRequest,
        encryptionPolicy: LoomSessionEncryptionPolicy = .required,
        enablePeerToPeer: Bool? = nil,
        requiredInterface: NWInterface? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        requiredLocalPort: UInt16? = nil,
        expectedPeerIdentityKeyID: String? = nil,
        expectedPeerIdentityPublicKey: Data? = nil,
        queue: DispatchQueue = .global(qos: .userInitiated),
        onTrustPending: (@Sendable @MainActor () -> Void)? = nil,
        onBootstrapProgress: (@Sendable (LoomAuthenticatedSessionBootstrapProgress) -> Void)? = nil
    ) async throws -> LoomAuthenticatedSession {
        // Pre-resolve .local mDNS hostnames to IP addresses so the
        // NWConnection doesn't stall in .waiting(ENETDOWN) on first use.
        let resolvedEndpoint: NWEndpoint
        let resolvedEnablePeerToPeer = enablePeerToPeer ?? configuration.enablePeerToPeer
        if case .hostPort(let host, let port) = endpoint,
           case .name(let hostname, _) = host,
           LoomEndpointResolver.shouldPreResolveLocalHost(
               hostname,
               enablePeerToPeer: resolvedEnablePeerToPeer
           ) {
            resolvedEndpoint = try await LoomEndpointResolver.resolveHostPort(
                host: hostname,
                port: port.rawValue
            )
        } else {
            resolvedEndpoint = endpoint
        }

        let identityManager = self.identityManager ?? LoomIdentityManager.shared

        func attemptConnect(to target: NWEndpoint) async throws -> LoomAuthenticatedSession {
            let connection = try LoomConnectionFactory.makeBackendConnection(
                to: target,
                using: transportKind,
                configuration: configuration,
                backend: networkBackend,
                enablePeerToPeer: enablePeerToPeer,
                requiredInterface: requiredInterface,
                requiredInterfaceType: requiredInterfaceType,
                requiredLocalPort: requiredLocalPort
            )
            let sess = LoomAuthenticatedSession(
                backendConnection: connection,
                role: .initiator,
                remoteEndpoint: LoomNetworkEndpoint(target),
                serviceClass: connection.transportKind == .tcp
                    ? nil
                    : configuration.backendDirectDatagramServiceClass,
                maximumConcurrentStreams: configuration.maximumConcurrentStreamsPerSession,
                maximumBufferedIncomingBytesPerStream: configuration.maximumBufferedIncomingBytesPerStream,
                maximumBufferedIncomingPayloadsPerStream: configuration.maximumBufferedIncomingPayloadsPerStream,
                maximumBufferedIncomingBytesPerSession: configuration.maximumBufferedIncomingBytesPerSession,
                maximumBufferedIncomingPayloadsPerSession: configuration.maximumBufferedIncomingPayloadsPerSession
            )
            await sess.setOnTrustPending(onTrustPending)
            await sess.setOnBootstrapProgress(onBootstrapProgress)
            return try await withTaskCancellationHandler {
                _ = try await sess.start(
                    localHello: hello,
                    identityManager: identityManager,
                    trustProvider: trustProvider,
                    encryptionPolicy: encryptionPolicy,
                    expectedPeerIdentityKeyID: expectedPeerIdentityKeyID,
                    expectedPeerIdentityPublicKey: expectedPeerIdentityPublicKey,
                    handshakeTimeout: configuration.authenticatedSessionHandshakeTimeout,
                    trustTimeout: configuration.authenticatedSessionTrustTimeout,
                    queue: queue
                )
                return sess
            } onCancel: {
                Task {
                    await sess.cancel()
                }
            }
        }

        do {
            return try await attemptConnect(to: resolvedEndpoint)
        } catch let error as LoomError {
            // NWConnection's first UDP socket binding can stall with ENETDOWN
            // when the interface path hasn't been exercised yet. A fresh
            // NWConnection to the same endpoint succeeds immediately.
            guard Self.isTransientNetworkDown(error) else { throw error }
            LoomLogger.transport("Recreating connection after transient ENETDOWN")
            return try await attemptConnect(to: resolvedEndpoint)
        }
    }
#endif

    /// Connects and authenticates using backend-independent endpoint and socket options.
    public func connect(
        to endpoint: LoomNetworkEndpoint,
        using transportKind: LoomTransportKind,
        hello: LoomSessionHelloRequest,
        encryptionPolicy: LoomSessionEncryptionPolicy = .required,
        networkConfiguration: LoomNetworkConnectionConfiguration? = nil,
        expectedPeerIdentityKeyID: String? = nil,
        expectedPeerIdentityPublicKey: Data? = nil,
        queue: DispatchQueue = .global(qos: .userInitiated),
        onTrustPending: (@Sendable @MainActor () -> Void)? = nil,
        onBootstrapProgress: (@Sendable (LoomAuthenticatedSessionBootstrapProgress) -> Void)? = nil
    ) async throws -> LoomAuthenticatedSession {
        let connection = try makeNetworkConnection(
            to: endpoint,
            using: transportKind,
            configuration: networkConfiguration
        )
        let session = LoomAuthenticatedSession(
            backendConnection: connection,
            role: .initiator,
            remoteEndpoint: endpoint,
            serviceClass: connection.transportKind == .tcp
                ? nil
                : (networkConfiguration?.datagramServiceClass ?? configuration.backendDirectDatagramServiceClass),
            maximumConcurrentStreams: configuration.maximumConcurrentStreamsPerSession,
            maximumBufferedIncomingBytesPerStream: configuration.maximumBufferedIncomingBytesPerStream,
            maximumBufferedIncomingPayloadsPerStream: configuration.maximumBufferedIncomingPayloadsPerStream,
            maximumBufferedIncomingBytesPerSession: configuration.maximumBufferedIncomingBytesPerSession,
            maximumBufferedIncomingPayloadsPerSession: configuration.maximumBufferedIncomingPayloadsPerSession
        )
        await session.setOnTrustPending(onTrustPending)
        await session.setOnBootstrapProgress(onBootstrapProgress)
        let identityManager = identityManager ?? LoomIdentityManager.shared
        return try await withTaskCancellationHandler {
            _ = try await session.start(
                localHello: hello,
                identityManager: identityManager,
                trustProvider: trustProvider,
                encryptionPolicy: encryptionPolicy,
                expectedPeerIdentityKeyID: expectedPeerIdentityKeyID,
                expectedPeerIdentityPublicKey: expectedPeerIdentityPublicKey,
                handshakeTimeout: configuration.authenticatedSessionHandshakeTimeout,
                trustTimeout: configuration.authenticatedSessionTrustTimeout,
                queue: queue
            )
            return session
        } onCancel: {
            Task {
                await session.cancel()
            }
        }
    }

    public func startAuthenticatedAdvertising(
        serviceName: String,
        encryptionPolicy: LoomSessionEncryptionPolicy = .required,
        helloProvider: @escaping @Sendable () async throws -> LoomSessionHelloRequest,
        onSession: @escaping @Sendable (LoomAuthenticatedSession) -> Void
    ) async throws -> [LoomTransportKind: UInt16] {
        guard !isStartingAuthenticatedAdvertising else {
            throw LoomError.alreadyAdvertising
        }
        isStartingAuthenticatedAdvertising = true
        defer {
            isStartingAuthenticatedAdvertising = false
        }

        let advertisingGeneration = UUID()
        authenticatedAdvertisingGeneration = advertisingGeneration
        do {
            // A sequential start is an atomic replacement. Tear down every
            // listener from the previous generation before binding new ports.
            await stopAdvertisingResources()
            try validateAuthenticatedAdvertisingGeneration(advertisingGeneration)
            let identityManager = self.identityManager ?? LoomIdentityManager.shared
            await preauthenticationWorkLimiter.updateLimit(configuration.maxPendingAuthenticatedSessions)
            await preauthenticationAdmission.updateLimit(configuration.maxPendingAuthenticatedSessions)
            await activeAuthenticatedSessionAdmission.updateLimit(configuration.maximumActiveAuthenticatedSessions)
            incomingRetainedCapacityBudget.updateLimits(
                maximumBytes: configuration.maximumBufferedIncomingBytesPerNode,
                maximumPayloadCount: configuration.maximumBufferedIncomingPayloadsPerNode,
                maximumBatchCount: configuration.maximumBufferedIncomingPayloadsPerNode
            )
            let handshakeTimeout = configuration.authenticatedSessionHandshakeTimeout
            let preauthenticationWorkLimiter = preauthenticationWorkLimiter
            let activeAuthenticatedSessionAdmission = activeAuthenticatedSessionAdmission
            let incomingRetainedCapacityBudget = incomingRetainedCapacityBudget
            // Verify identity is accessible before accepting connections.
            // Fails fast at startup if Keychain is unavailable.
            _ = try await MainActor.run { try identityManager.currentIdentity() }
            let baseHello = try await withLoomThrowingTimeout(handshakeTimeout) {
                try await preauthenticationWorkLimiter.run {
                    try await helloProvider()
                }
            }
            try validateAuthenticatedAdvertisingGeneration(advertisingGeneration)
            let directDatagramServiceClass = configuration.backendDirectDatagramServiceClass
            let trustTimeout = configuration.authenticatedSessionTrustTimeout
            let maximumConcurrentStreams = configuration.maximumConcurrentStreamsPerSession
            let maximumBufferedIncomingBytesPerStream = configuration.maximumBufferedIncomingBytesPerStream
            let maximumBufferedIncomingPayloadsPerStream = configuration.maximumBufferedIncomingPayloadsPerStream
            let maximumBufferedIncomingBytesPerSession = configuration.maximumBufferedIncomingBytesPerSession
            let maximumBufferedIncomingPayloadsPerSession = configuration.maximumBufferedIncomingPayloadsPerSession
            let preauthenticationAdmission = preauthenticationAdmission
            var ports: [LoomTransportKind: UInt16] = [:]

            // Start datagram-capable direct listeners before publishing Bonjour.
            // Otherwise clients can discover a valid local service with no
            // datagram-capable hint and lock the session onto TCP before the
            // TXT update arrives.
            if configuration.enabledDirectTransports.contains(.udp) {
                let udpPort = try await startAuthenticatedDirectListener(
                    transportKind: .udp,
                    requestedPort: configuration.udpPort,
                    identityManager: identityManager,
                    encryptionPolicy: encryptionPolicy,
                    handshakeTimeout: handshakeTimeout,
                    trustTimeout: trustTimeout,
                    maximumConcurrentStreams: maximumConcurrentStreams,
                    maximumBufferedIncomingBytesPerStream: maximumBufferedIncomingBytesPerStream,
                    maximumBufferedIncomingPayloadsPerStream: maximumBufferedIncomingPayloadsPerStream,
                    maximumBufferedIncomingBytesPerSession: maximumBufferedIncomingBytesPerSession,
                    maximumBufferedIncomingPayloadsPerSession: maximumBufferedIncomingPayloadsPerSession,
                    preauthenticationAdmission: preauthenticationAdmission,
                    preauthenticationWorkLimiter: preauthenticationWorkLimiter,
                    activeAuthenticatedSessionAdmission: activeAuthenticatedSessionAdmission,
                    incomingRetainedCapacityBudget: incomingRetainedCapacityBudget,
                    advertisingGeneration: advertisingGeneration,
                    helloProvider: helloProvider,
                    onSession: onSession
                )
                ports[.udp] = udpPort
                try validateAuthenticatedAdvertisingGeneration(advertisingGeneration)
            }

            let initialBonjourAdvertisement = Self.advertisement(
                baseHello.advertisement,
                withDirectTransportPorts: ports,
                serviceName: serviceName
            )
            let port = try await startAdvertising(
                serviceName: serviceName,
                advertisement: initialBonjourAdvertisement,
                authenticatedGeneration: advertisingGeneration
            ) { [weak self] connection in
                guard let self else { return }
                guard await MainActor.run(body: {
                    self.authenticatedAdvertisingGeneration == advertisingGeneration
                }) else {
                    await connection.cancel()
                    return
                }
                guard await preauthenticationAdmission.acquire() else {
                    LoomLogger.transport(
                        "Rejected authenticated tcp listener connection before handshake: admission limit reached"
                    )
                    await connection.cancel()
                    return
                }
                let session = LoomAuthenticatedSession(
                    backendConnection: connection,
                    role: .receiver,
                    remoteEndpoint: connection.remoteEndpoint,
                    serviceClass: connection.transportKind == .tcp
                        ? nil
                        : directDatagramServiceClass,
                    maximumConcurrentStreams: maximumConcurrentStreams,
                    maximumBufferedIncomingBytesPerStream: maximumBufferedIncomingBytesPerStream,
                    maximumBufferedIncomingPayloadsPerStream: maximumBufferedIncomingPayloadsPerStream,
                    maximumBufferedIncomingBytesPerSession: maximumBufferedIncomingBytesPerSession,
                    maximumBufferedIncomingPayloadsPerSession: maximumBufferedIncomingPayloadsPerSession
                )
                session.setParentIncomingRetainedCapacityBudget(incomingRetainedCapacityBudget)
                await session.setPreauthenticationOperationLimiter(preauthenticationWorkLimiter)
                let sessionID = session.id.uuidString.lowercased()
                let endpointDescription = connection.remoteEndpoint.description
                LoomLogger.transport(
                    "Accepted authenticated tcp listener session sessionID=\(sessionID) " +
                        "endpoint=\(endpointDescription) service=\(serviceName)"
                )
                await Self.installAuthenticatedListenerBootstrapProgressLogger(
                    on: session,
                    transportKind: LoomTransportKind(connection.transportKind),
                    endpointDescription: endpointDescription,
                    serviceName: serviceName
                )
                do {
                    let preauthenticationDeadline = ContinuousClock.now + handshakeTimeout
                    let hello = try await withLoomThrowingDeadline(
                        preauthenticationDeadline,
                        onTimeout: {
                            Task {
                                await connection.cancel()
                            }
                        }
                    ) {
                        try await preauthenticationWorkLimiter.run {
                            try await helloProvider()
                        }
                    }
                    let remainingHandshakeTimeout = max(
                        .milliseconds(1),
                        ContinuousClock.now.duration(to: preauthenticationDeadline)
                    )
                    _ = try await session.start(
                        localHello: hello,
                        identityManager: identityManager,
                        trustProvider: self.trustProvider,
                        encryptionPolicy: encryptionPolicy,
                        handshakeTimeout: remainingHandshakeTimeout,
                        trustTimeout: trustTimeout
                    )
                    guard await MainActor.run(body: {
                        self.authenticatedAdvertisingGeneration == advertisingGeneration
                    }) else {
                        await preauthenticationAdmission.release()
                        await session.cancel()
                        return
                    }
                    guard await activeAuthenticatedSessionAdmission.acquire() else {
                        await preauthenticationAdmission.release()
                        LoomLogger.transport(
                            "Rejected authenticated tcp listener session after handshake: active session limit reached"
                        )
                        await session.cancel()
                        return
                    }
                    Self.monitorAcceptedSession(
                        session,
                        admission: activeAuthenticatedSessionAdmission
                    )
                    await preauthenticationAdmission.release()
                    onSession(session)
                } catch {
                    await preauthenticationAdmission.release()
                    Self.logAcceptedAuthenticatedSessionFailure(
                        error,
                        transportKind: LoomTransportKind(connection.transportKind),
                        sessionID: sessionID,
                        serviceName: serviceName
                    )
                    await session.cancel()
                }
            }

            try validateAuthenticatedAdvertisingGeneration(advertisingGeneration)
            ports[.tcp] = port
            try await startOverlayProbeServer(
                serviceName: serviceName,
                advertisingGeneration: advertisingGeneration
            )
            try validateAuthenticatedAdvertisingGeneration(advertisingGeneration)
            return ports
        } catch {
            if authenticatedAdvertisingGeneration == advertisingGeneration {
                await stopAdvertising()
            }
            throw error
        }
    }

    private func startAuthenticatedDirectListener(
        transportKind: LoomTransportKind,
        requestedPort: UInt16,
        identityManager: LoomIdentityManager,
        encryptionPolicy: LoomSessionEncryptionPolicy,
        handshakeTimeout: Duration,
        trustTimeout: Duration,
        maximumConcurrentStreams: Int,
        maximumBufferedIncomingBytesPerStream: Int,
        maximumBufferedIncomingPayloadsPerStream: Int,
        maximumBufferedIncomingBytesPerSession: Int,
        maximumBufferedIncomingPayloadsPerSession: Int,
        preauthenticationAdmission: LoomPreauthenticationAdmissionController,
        preauthenticationWorkLimiter: LoomOutstandingOperationLimiter,
        activeAuthenticatedSessionAdmission: LoomPreauthenticationAdmissionController,
        incomingRetainedCapacityBudget: LoomIncomingRetainedCapacityBudget,
        advertisingGeneration: UUID,
        helloProvider: @escaping @Sendable () async throws -> LoomSessionHelloRequest,
        onSession: @escaping @Sendable (LoomAuthenticatedSession) -> Void
    ) async throws -> UInt16 {
        let directDatagramServiceClass = configuration.backendDirectDatagramServiceClass
        let listener = try makeDirectTransportListener(for: transportKind)
        directListeners[transportKind] = listener
        let port: UInt16
        do {
            port = try await listener.start(port: requestedPort) { [weak self] connection in
            guard let self else { return }
            guard await MainActor.run(body: {
                self.authenticatedAdvertisingGeneration == advertisingGeneration
            }) else {
                await connection.cancel()
                return
            }
            guard await preauthenticationAdmission.acquire() else {
                LoomLogger.transport(
                    "Rejected authenticated \(connection.transportKind.rawValue) direct connection before handshake: " +
                        "admission limit reached"
                )
                await connection.cancel()
                return
            }
            let session = LoomAuthenticatedSession(
                backendConnection: connection,
                role: .receiver,
                remoteEndpoint: connection.remoteEndpoint,
                serviceClass: connection.transportKind == .tcp
                    ? nil
                    : directDatagramServiceClass,
                maximumConcurrentStreams: maximumConcurrentStreams,
                maximumBufferedIncomingBytesPerStream: maximumBufferedIncomingBytesPerStream,
                maximumBufferedIncomingPayloadsPerStream: maximumBufferedIncomingPayloadsPerStream,
                maximumBufferedIncomingBytesPerSession: maximumBufferedIncomingBytesPerSession,
                maximumBufferedIncomingPayloadsPerSession: maximumBufferedIncomingPayloadsPerSession
            )
            session.setParentIncomingRetainedCapacityBudget(incomingRetainedCapacityBudget)
            await session.setPreauthenticationOperationLimiter(preauthenticationWorkLimiter)
            let sessionID = session.id.uuidString.lowercased()
            let endpointDescription = connection.remoteEndpoint.description
            LoomLogger.transport(
                "Accepted authenticated \(connection.transportKind.rawValue) direct listener session " +
                    "sessionID=\(sessionID) endpoint=\(endpointDescription)"
            )
            await Self.installAuthenticatedListenerBootstrapProgressLogger(
                on: session,
                transportKind: LoomTransportKind(connection.transportKind),
                endpointDescription: endpointDescription,
                serviceName: nil
            )
            do {
                let preauthenticationDeadline = ContinuousClock.now + handshakeTimeout
                let hello = try await withLoomThrowingDeadline(
                    preauthenticationDeadline,
                    onTimeout: {
                        Task {
                            await connection.cancel()
                        }
                    }
                ) {
                    try await preauthenticationWorkLimiter.run {
                        try await helloProvider()
                    }
                }
                let remainingHandshakeTimeout = max(
                    .milliseconds(1),
                    ContinuousClock.now.duration(to: preauthenticationDeadline)
                )
                _ = try await session.start(
                    localHello: hello,
                    identityManager: identityManager,
                    trustProvider: self.trustProvider,
                    encryptionPolicy: encryptionPolicy,
                    handshakeTimeout: remainingHandshakeTimeout,
                    trustTimeout: trustTimeout
                )
                guard await MainActor.run(body: {
                    self.authenticatedAdvertisingGeneration == advertisingGeneration
                }) else {
                    await preauthenticationAdmission.release()
                    await session.cancel()
                    return
                }
                guard await activeAuthenticatedSessionAdmission.acquire() else {
                    await preauthenticationAdmission.release()
                    LoomLogger.transport(
                        "Rejected authenticated \(connection.transportKind.rawValue) direct session after handshake: " +
                            "active session limit reached"
                    )
                    await session.cancel()
                    return
                }
                Self.monitorAcceptedSession(
                    session,
                    admission: activeAuthenticatedSessionAdmission
                )
                await preauthenticationAdmission.release()
                onSession(session)
            } catch {
                await preauthenticationAdmission.release()
                Self.logAcceptedAuthenticatedSessionFailure(
                    error,
                    transportKind: LoomTransportKind(connection.transportKind),
                    sessionID: sessionID,
                    serviceName: nil
                )
                await session.cancel()
            }
            }
            try validateAuthenticatedAdvertisingGeneration(advertisingGeneration)
        } catch {
            if isCurrentDirectListener(listener, for: transportKind) {
                directListeners.removeValue(forKey: transportKind)
            }
            await listener.stop()
            throw error
        }
        directListenerPorts[transportKind] = port
        return port
    }

    private static func installAuthenticatedListenerBootstrapProgressLogger(
        on session: LoomAuthenticatedSession,
        transportKind: LoomTransportKind,
        endpointDescription: String,
        serviceName: String?
    ) async {
        let sessionID = session.id.uuidString.lowercased()
        let serviceText = serviceName.map { " service=\($0)" } ?? ""
        await session.setOnBootstrapProgress { progress in
            let failureText = progress.failureReason.map { " failure=\($0)" } ?? ""
            LoomLogger.transport(
                "Authenticated \(transportKind.rawValue) listener session bootstrap " +
                    "sessionID=\(sessionID) endpoint=\(endpointDescription)\(serviceText) " +
                    "phase=\(progress.phase.rawValue)\(failureText)"
            )
        }
    }

    nonisolated private static func logAcceptedAuthenticatedSessionFailure(
        _ error: Error,
        transportKind: LoomTransportKind,
        sessionID: String,
        serviceName: String?
    ) {
        let serviceText = serviceName.map { " service=\($0)" } ?? ""
        let prefix = "Authenticated \(transportKind.rawValue) listener session failed sessionID=\(sessionID)\(serviceText)"
        if isExpectedAcceptedSessionFailure(error) {
            LoomLogger.transport("\(prefix): \(error.localizedDescription)")
        } else {
            LoomLogger.error(
                .transport,
                error: error,
                message: prefix
            )
        }
    }

    nonisolated private static func isExpectedAcceptedSessionFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let loomError = error as? LoomError {
            switch loomError {
            case .authenticationFailed:
                return true
            case let .connectionFailed(underlying):
                let failure = LoomConnectionFailure.classify(underlying)
                return failure.reason == .cancelled ||
                    failure.reason == .closed ||
                    failure.reason == .transportLoss
            default:
                return false
            }
        }
        let failure = LoomConnectionFailure.classify(error)
        return failure.reason == .cancelled || failure.reason == .closed
    }

    private static func keepAcceptedSessionAlive(_ session: LoomAuthenticatedSession) async {
        let states = await session.makeStateObserver()
        for await state in states {
            switch state {
            case .cancelled, .failed:
                return
            case .idle, .handshaking, .ready:
                break
            }
        }
    }

    private nonisolated static func monitorAcceptedSession(
        _ session: LoomAuthenticatedSession,
        admission: LoomPreauthenticationAdmissionController
    ) {
        Task {
            await keepAcceptedSessionAlive(session)
            await admission.release()
        }
    }

    package var activeAuthenticatedSessionCountForTesting: Int {
        get async {
            await activeAuthenticatedSessionAdmission.activeCount
        }
    }

    package var retainedIncomingBytesForTesting: Int {
        incomingRetainedCapacityBudget.retainedBytesForTesting
    }

    package func admitAuthenticatedSessionForTesting(
        _ session: LoomAuthenticatedSession
    ) async -> Bool {
        await activeAuthenticatedSessionAdmission.updateLimit(configuration.maximumActiveAuthenticatedSessions)
        guard await activeAuthenticatedSessionAdmission.acquire() else { return false }
        Self.monitorAcceptedSession(
            session,
            admission: activeAuthenticatedSessionAdmission
        )
        return true
    }

    private func validateAuthenticatedAdvertisingGeneration(_ generation: UUID) throws {
        guard authenticatedAdvertisingGeneration == generation else {
            throw CancellationError()
        }
    }

    private func makeDirectTransportListener(
        for transportKind: LoomTransportKind
    ) throws -> any LoomDirectTransportListener {
        switch transportKind {
        case .tcp, .udp:
            return LoomDirectListener(
                listener: try networkBackend.makeListener(
                    using: transportKind.networkTransportKind,
                    configuration: LoomNetworkListenerConfiguration(
                        enablePeerToPeer: configuration.enablePeerToPeer,
                        datagramServiceClass: configuration.backendDirectDatagramServiceClass
                    )
                )
            )
        case .quic:
            throw LoomError.protocolError("QUIC transport has been removed.")
        }
    }

    private func isCurrentDirectListener(
        _ listener: any LoomDirectTransportListener,
        for transportKind: LoomTransportKind
    ) -> Bool {
        guard let current = directListeners[transportKind] else { return false }
        return ObjectIdentifier(current as AnyObject) == ObjectIdentifier(listener as AnyObject)
    }

    private func startBonjourAdvertising(context: BonjourAdvertisingContext?) async throws -> UInt16 {
        guard let context else {
            throw LoomError.protocolError("Bonjour advertising context is unavailable.")
        }

        let generation = UUID()
        bonjourAdvertisingGeneration = generation
        advertisingDiagnostics = advertisingDiagnostics.updating(
            state: bonjourAdvertisingRecoveryAttempt == 0 ? .starting : .recovering,
            serviceName: context.serviceName,
            directListenerPorts: directListenerPorts,
            bonjourRecoveryAttempt: bonjourAdvertisingRecoveryAttempt
        )

        let onFailureAfterReady: @Sendable (String) -> Void = { [weak self] failureDescription in
            Task { @MainActor [weak self] in
                self?.handleBonjourAdvertisingFailure(
                    failureDescription,
                    generation: generation
                )
            }
        }
#if canImport(Network)
        let advertiser = BonjourAdvertiser(
            serviceName: context.serviceName,
            advertisement: context.advertisement,
            serviceType: configuration.serviceType,
            enablePeerToPeer: configuration.enablePeerToPeer,
            onFailureAfterReady: onFailureAfterReady
        )
#else
        let advertiser = BonjourAdvertiser(
            serviceName: context.serviceName,
            advertisement: context.advertisement,
            serviceType: configuration.serviceType,
            enablePeerToPeer: configuration.enablePeerToPeer,
            networkBackend: networkBackend,
            onFailureAfterReady: onFailureAfterReady
        )
#endif
        self.advertiser = advertiser
        let port: UInt16
        do {
            port = try await advertiser.start(
                port: configuration.controlPort,
                onConnection: context.onConnection
            )
        } catch {
            if generation == bonjourAdvertisingGeneration {
                self.advertiser = nil
            }
            await advertiser.stop()
            throw error
        }
        guard generation == bonjourAdvertisingGeneration,
              self.advertiser === advertiser else {
            await advertiser.stop()
            throw CancellationError()
        }
        let publishedAdvertisement = Self.advertisement(
            context.advertisement,
            withDirectTransportPorts: directTransportPorts(advertiserTCPPort: port),
            serviceName: context.serviceName
        )
        self.publishedAdvertisement = publishedAdvertisement
        await advertiser.updateAdvertisement(publishedAdvertisement)
        guard generation == bonjourAdvertisingGeneration,
              self.advertiser === advertiser else {
            await advertiser.stop()
            throw CancellationError()
        }
        bonjourAdvertisingRecoveryAttempt = 0
        advertisingDiagnostics = advertisingDiagnostics.updating(
            state: .advertising,
            serviceName: context.serviceName,
            bonjourPort: port,
            directListenerPorts: directListenerPorts,
            bonjourRecoveryAttempt: 0
        )
        return port
    }

    private func handleBonjourAdvertisingFailure(
        _ failureDescription: String,
        generation: UUID
    ) {
        guard generation == bonjourAdvertisingGeneration else { return }

        LoomLogger.discovery("Bonjour advertiser failed after publishing: \(failureDescription)")
        bonjourAdvertisingGeneration = UUID()
        bonjourAdvertisingRecoveryAttempt += 1
        let recoveryAttempt = bonjourAdvertisingRecoveryAttempt
        advertisingDiagnostics = advertisingDiagnostics.recordingBonjourFailure(
            failureDescription,
            at: Date(),
            recoveryAttempt: recoveryAttempt
        )

        let failedAdvertiser = advertiser
        advertiser = nil
        Task {
            await failedAdvertiser?.stop()
        }
        scheduleBonjourAdvertisingRecovery(attempt: recoveryAttempt)
    }

    private func scheduleBonjourAdvertisingRecovery(attempt: Int) {
        bonjourAdvertisingRecoveryTask?.cancel()
        let delay = Self.bonjourAdvertisingRecoveryDelay(attempt: attempt)
        let authenticatedGeneration = authenticatedAdvertisingGeneration
        bonjourAdvertisingRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            await self?.recoverBonjourAdvertising(
                authenticatedGeneration: authenticatedGeneration
            )
        }
    }

    private func recoverBonjourAdvertising(authenticatedGeneration: UUID) async {
        guard authenticatedGeneration == authenticatedAdvertisingGeneration,
              configuration.enableBonjour,
              bonjourAdvertisingContext != nil,
              advertisingServiceName != nil else {
            return
        }

        do {
            _ = try await startBonjourAdvertising(context: bonjourAdvertisingContext)
            guard authenticatedGeneration == authenticatedAdvertisingGeneration else { return }
            bonjourAdvertisingRecoveryTask = nil
            LoomLogger.discovery("Bonjour advertiser recovered")
        } catch is CancellationError {
            return
        } catch {
            guard authenticatedGeneration == authenticatedAdvertisingGeneration,
                  bonjourAdvertisingContext != nil,
                  advertisingServiceName != nil else {
                return
            }
            bonjourAdvertisingRecoveryTask = nil
            LoomLogger.discovery("Bonjour advertiser recovery failed: \(error)")
            bonjourAdvertisingRecoveryAttempt += 1
            let recoveryAttempt = bonjourAdvertisingRecoveryAttempt
            advertisingDiagnostics = advertisingDiagnostics.recordingBonjourFailure(
                String(describing: error),
                at: Date(),
                recoveryAttempt: recoveryAttempt
            )
            scheduleBonjourAdvertisingRecovery(attempt: recoveryAttempt)
        }
    }

    nonisolated package static func bonjourAdvertisingRecoveryDelay(attempt: Int) -> Duration {
        guard attempt > 1 else { return minimumBonjourAdvertisingRecoveryDelay }

        var seconds = 1
        for _ in 1..<attempt {
            seconds = min(seconds * 2, 30)
        }
        return .seconds(seconds)
    }

    private func directTransportPorts(advertiserTCPPort: UInt16?) -> [LoomTransportKind: UInt16] {
        var ports = directListenerPorts
        if let advertiserTCPPort {
            ports[.tcp] = advertiserTCPPort
        }
        return ports
    }

    private func startOverlayProbeServer(
        serviceName: String,
        advertisingGeneration: UUID
    ) async throws {
#if canImport(Network)
        guard let overlayProbePort = configuration.overlayProbePort else {
            return
        }

        let existingProbeServer = overlayProbeServer
        overlayProbeServer = nil
        await existingProbeServer?.stop()
        let probeServer = LoomOverlayProbeServer(
            port: overlayProbePort,
            requestTimeout: configuration.authenticatedSessionHandshakeTimeout,
            maxPendingConnections: configuration.maxPendingAuthenticatedSessions
        ) {
            guard let advertisement = await MainActor.run(body: { self.publishedAdvertisement }) else {
                throw LoomError.protocolError("Overlay probe advertisement is unavailable.")
            }
            return LoomOverlayProbeResponse(
                name: serviceName,
                deviceType: advertisement.deviceType ?? .unknown,
                advertisement: advertisement
            )
        }
        overlayProbeServer = probeServer
        do {
            _ = try await probeServer.start()
            try validateAuthenticatedAdvertisingGeneration(advertisingGeneration)
        } catch {
            if overlayProbeServer === probeServer {
                overlayProbeServer = nil
            }
            await probeServer.stop()
            throw error
        }
#endif
    }

    private static func isTransientNetworkDown(_ error: LoomError) -> Bool {
        guard case .connectionFailed(let underlying) = error else { return false }
        let failure = LoomConnectionFailure.classify(underlying)
        guard let code = failure.posixCode else { return false }
        return ([.ENETDOWN, .EHOSTUNREACH, .ENETUNREACH] as [POSIXErrorCode]).contains(code)
    }

    nonisolated static func advertisement(
        _ base: LoomPeerAdvertisement,
        withDirectTransportPorts ports: [LoomTransportKind: UInt16],
        serviceName: String?
    ) -> LoomPeerAdvertisement {
        let pathKindsByTransport = base.directTransports.reduce(into: [LoomTransportKind: LoomDirectPathKind?]()) { partialResult, transport in
            partialResult[transport.transportKind] = transport.pathKind
        }
        let directTransports: [LoomDirectTransportAdvertisement] = LoomTransportKind.allCases.compactMap { transportKind in
            guard let port = ports[transportKind], port > 0 else {
                return nil
            }
            return LoomDirectTransportAdvertisement(
                transportKind: transportKind,
                port: port,
                pathKind: pathKindsByTransport[transportKind] ?? nil
            )
        }

        return LoomPeerAdvertisement(
            protocolVersion: base.protocolVersion,
            deviceID: base.deviceID,
            identityKeyID: base.identityKeyID,
            deviceType: base.deviceType,
            modelIdentifier: base.modelIdentifier,
            iconName: base.iconName,
            machineFamily: base.machineFamily,
            hostName: base.hostName,
            directTransports: directTransports,
            metadata: base.metadata
        )
    }

}
