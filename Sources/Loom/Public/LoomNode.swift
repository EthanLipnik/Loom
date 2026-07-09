//
//  LoomNode.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Network
import Observation

/// Direct transport kinds backed by `NWConnection`.
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

    package var backingNWConnection: NWConnection? {
        switch self {
        case let .tcp(connection), let .udp(connection):
            connection
        }
    }
}

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
    private var overlayProbeServer: LoomOverlayProbeServer?
    private var bonjourAdvertisingContext: BonjourAdvertisingContext?
    private var bonjourAdvertisingGeneration = UUID()
    private var bonjourAdvertisingRecoveryTask: Task<Void, Never>?
    private var bonjourAdvertisingRecoveryAttempt = 0

    nonisolated private static let minimumBonjourAdvertisingRecoveryDelay: Duration = .seconds(1)

    public init(
        configuration: LoomNetworkConfiguration = .default,
        identityManager: LoomIdentityManager? = LoomIdentityManager.shared,
        trustProvider: (any LoomTrustProvider)? = nil
    ) {
        self.configuration = configuration
        self.identityManager = identityManager
        self.trustProvider = trustProvider
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
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16 {
        advertisingServiceName = serviceName
        bonjourAdvertisingRecoveryTask?.cancel()

        guard configuration.enableBonjour else {
            let directListener = try makeDirectTransportListener(for: .tcp)
            advertisingDiagnostics = advertisingDiagnostics.updating(
                state: .starting,
                serviceName: serviceName,
                directListenerPorts: directListenerPorts,
                bonjourRecoveryAttempt: 0
            )
            let port = try await directListener.start(
                port: configuration.controlPort,
                onConnection: onConnection
            )
            directListeners[.tcp] = directListener
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
        return try await startBonjourAdvertising(context: bonjourAdvertisingContext)
    }

    public func stopAdvertising() async {
        bonjourAdvertisingRecoveryTask?.cancel()
        bonjourAdvertisingRecoveryTask = nil
        bonjourAdvertisingGeneration = UUID()
        bonjourAdvertisingContext = nil
        bonjourAdvertisingRecoveryAttempt = 0
        let overlayProbeServer = self.overlayProbeServer
        self.overlayProbeServer = nil
        let advertiser = self.advertiser
        self.advertiser = nil
        advertisingServiceName = nil
        publishedAdvertisement = nil
        let directListeners = self.directListeners.values
        self.directListeners.removeAll()
        self.directListenerPorts.removeAll()

        await overlayProbeServer?.stop()
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

    public func makeAuthenticatedSession(
        connection: LoomConnection,
        role: LoomSessionRole,
        remoteEndpoint: NWEndpoint? = nil
    ) -> LoomAuthenticatedSession {
        LoomAuthenticatedSession(
            connection: connection,
            role: role,
            remoteEndpoint: remoteEndpoint,
            serviceClass: connection.transportKind == .tcp ? nil : configuration.directDatagramServiceClass
        )
    }

    public func makeConnection(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        enablePeerToPeer: Bool? = nil,
        requiredInterface: NWInterface? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        requiredLocalPort: UInt16? = nil
    ) throws -> LoomConnection {
        try LoomConnectionFactory.makeConnection(
            to: endpoint,
            using: transportKind,
            configuration: configuration,
            enablePeerToPeer: enablePeerToPeer ?? configuration.enablePeerToPeer,
            requiredInterface: requiredInterface,
            requiredInterfaceType: requiredInterfaceType,
            requiredLocalPort: requiredLocalPort
        )
    }

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
            let connection = try makeConnection(
                to: target,
                using: transportKind,
                enablePeerToPeer: enablePeerToPeer,
                requiredInterface: requiredInterface,
                requiredInterfaceType: requiredInterfaceType,
                requiredLocalPort: requiredLocalPort
            )
            let sess = makeAuthenticatedSession(
                connection: connection,
                role: .initiator,
                remoteEndpoint: target
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

    public func startAuthenticatedAdvertising(
        serviceName: String,
        encryptionPolicy: LoomSessionEncryptionPolicy = .required,
        helloProvider: @escaping @Sendable () async throws -> LoomSessionHelloRequest,
        onSession: @escaping @Sendable (LoomAuthenticatedSession) -> Void
    ) async throws -> [LoomTransportKind: UInt16] {
        do {
            let identityManager = self.identityManager ?? LoomIdentityManager.shared
            // Verify identity is accessible before accepting connections.
            // Fails fast at startup if Keychain is unavailable.
            _ = try await MainActor.run { try identityManager.currentIdentity() }
            let baseHello = try await helloProvider()
            let directDatagramServiceClass = configuration.directDatagramServiceClass
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
                    helloProvider: helloProvider,
                    onSession: onSession
                )
                ports[.udp] = udpPort
            }

            let initialBonjourAdvertisement = Self.advertisement(
                baseHello.advertisement,
                withDirectTransportPorts: ports,
                serviceName: serviceName
            )
            let port = try await startAdvertising(
                serviceName: serviceName,
                advertisement: initialBonjourAdvertisement
            ) { [weak self] connection in
                guard let self else { return }
                let session = LoomAuthenticatedSession(
                    connection: connection,
                    role: .receiver,
                    remoteEndpoint: connection.endpoint,
                    serviceClass: connection.transportKind == .tcp ? nil : directDatagramServiceClass
                )
                let sessionID = session.id.uuidString.lowercased()
                let endpointDescription = connection.endpoint.debugDescription
                LoomLogger.transport(
                    "Accepted authenticated tcp listener session sessionID=\(sessionID) " +
                        "endpoint=\(endpointDescription) service=\(serviceName)"
                )
                await Self.installAuthenticatedListenerBootstrapProgressLogger(
                    on: session,
                    transportKind: connection.transportKind,
                    endpointDescription: endpointDescription,
                    serviceName: serviceName
                )
                do {
                    let hello = try await helloProvider()
                    _ = try await session.start(
                        localHello: hello,
                        identityManager: identityManager,
                        trustProvider: self.trustProvider,
                        encryptionPolicy: encryptionPolicy
                    )
                    onSession(session)
                    await Self.keepAcceptedSessionAlive(session)
                } catch {
                    Self.logAcceptedAuthenticatedSessionFailure(
                        error,
                        transportKind: connection.transportKind,
                        sessionID: sessionID,
                        serviceName: serviceName
                    )
                    await session.cancel()
                }
            }

            ports[.tcp] = port
            try await startOverlayProbeServer(serviceName: serviceName)
            return ports
        } catch {
            await stopAdvertising()
            throw error
        }
    }

    private func startAuthenticatedDirectListener(
        transportKind: LoomTransportKind,
        requestedPort: UInt16,
        identityManager: LoomIdentityManager,
        encryptionPolicy: LoomSessionEncryptionPolicy,
        helloProvider: @escaping @Sendable () async throws -> LoomSessionHelloRequest,
        onSession: @escaping @Sendable (LoomAuthenticatedSession) -> Void
    ) async throws -> UInt16 {
        let directDatagramServiceClass = configuration.directDatagramServiceClass
        let listener = try makeDirectTransportListener(for: transportKind)
        let port = try await listener.start(port: requestedPort) { [weak self] connection in
            guard let self else { return }
            let session = LoomAuthenticatedSession(
                connection: connection,
                role: .receiver,
                remoteEndpoint: connection.endpoint,
                serviceClass: connection.transportKind == .tcp ? nil : directDatagramServiceClass
            )
            let sessionID = session.id.uuidString.lowercased()
            let endpointDescription = connection.endpoint.debugDescription
            LoomLogger.transport(
                "Accepted authenticated \(connection.transportKind.rawValue) direct listener session " +
                    "sessionID=\(sessionID) endpoint=\(endpointDescription)"
            )
            await Self.installAuthenticatedListenerBootstrapProgressLogger(
                on: session,
                transportKind: connection.transportKind,
                endpointDescription: endpointDescription,
                serviceName: nil
            )
            do {
                let hello = try await helloProvider()
                _ = try await session.start(
                    localHello: hello,
                    identityManager: identityManager,
                    trustProvider: self.trustProvider,
                    encryptionPolicy: encryptionPolicy
                )
                onSession(session)
                await Self.keepAcceptedSessionAlive(session)
            } catch {
                Self.logAcceptedAuthenticatedSessionFailure(
                    error,
                    transportKind: connection.transportKind,
                    sessionID: sessionID,
                    serviceName: nil
                )
                await session.cancel()
            }
        }
        directListeners[transportKind] = listener
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

    private func makeDirectTransportListener(
        for transportKind: LoomTransportKind
    ) throws -> any LoomDirectTransportListener {
        switch transportKind {
        case .tcp, .udp:
            guard let nwTransportKind = LoomNWConnectionTransportKind(transportKind) else {
                throw LoomError.protocolError("Transport \(transportKind.rawValue) is not backed by NWConnection.")
            }
            return LoomDirectListener(
                transportKind: nwTransportKind,
                enablePeerToPeer: configuration.enablePeerToPeer,
                udpServiceClass: configuration.directDatagramServiceClass
            )
        case .quic:
            throw LoomError.protocolError("QUIC transport has been removed.")
        }
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

        let advertiser = BonjourAdvertiser(
            serviceName: context.serviceName,
            advertisement: context.advertisement,
            serviceType: configuration.serviceType,
            enablePeerToPeer: configuration.enablePeerToPeer,
            onFailureAfterReady: { [weak self] failureDescription in
                Task { @MainActor [weak self] in
                    self?.handleBonjourAdvertisingFailure(
                        failureDescription,
                        generation: generation
                    )
                }
            }
        )
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
        let publishedAdvertisement = Self.advertisement(
            context.advertisement,
            withDirectTransportPorts: directTransportPorts(advertiserTCPPort: port),
            serviceName: context.serviceName
        )
        self.publishedAdvertisement = publishedAdvertisement
        await advertiser.updateAdvertisement(publishedAdvertisement)
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
        bonjourAdvertisingRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            await self?.recoverBonjourAdvertising()
        }
    }

    private func recoverBonjourAdvertising() async {
        bonjourAdvertisingRecoveryTask = nil
        guard configuration.enableBonjour,
              bonjourAdvertisingContext != nil,
              advertisingServiceName != nil else {
            return
        }

        do {
            _ = try await startBonjourAdvertising(context: bonjourAdvertisingContext)
            LoomLogger.discovery("Bonjour advertiser recovered")
        } catch {
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

    private func startOverlayProbeServer(serviceName: String) async throws {
        guard let overlayProbePort = configuration.overlayProbePort else {
            return
        }

        let existingProbeServer = overlayProbeServer
        overlayProbeServer = nil
        await existingProbeServer?.stop()
        let probeServer = LoomOverlayProbeServer(port: overlayProbePort) {
            guard let advertisement = await MainActor.run(body: { self.publishedAdvertisement }) else {
                throw LoomError.protocolError("Overlay probe advertisement is unavailable.")
            }
            return LoomOverlayProbeResponse(
                name: serviceName,
                deviceType: advertisement.deviceType ?? .unknown,
                advertisement: advertisement
            )
        }
        _ = try await probeServer.start()
        overlayProbeServer = probeServer
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
