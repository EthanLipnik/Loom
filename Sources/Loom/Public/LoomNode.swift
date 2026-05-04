//
//  LoomNode.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Network
import Observation

@Observable
@MainActor
public final class LoomNode {
    public var configuration: LoomNetworkConfiguration
    public var identityManager: LoomIdentityManager?
    public weak var trustProvider: (any LoomTrustProvider)?

    public private(set) var discovery: LoomDiscovery?

    private var advertiser: BonjourAdvertiser?
    private var advertisingServiceName: String?
    private var publishedAdvertisement: LoomPeerAdvertisement?
    private var directListeners: [LoomTransportKind: LoomDirectListener] = [:]
    private var directListenerPorts: [LoomTransportKind: UInt16] = [:]
    private var overlayProbeServer: LoomOverlayProbeServer?

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
            if let localDeviceID {
                discovery.localDeviceID = localDeviceID
            }
            return discovery
        }

        let discovery = LoomDiscovery(
            serviceType: configuration.serviceType,
            enableBonjour: configuration.enableBonjour,
            enablePeerToPeer: configuration.enablePeerToPeer,
            localDeviceID: localDeviceID
        )
        self.discovery = discovery
        return discovery
    }

    public func startAdvertising(
        serviceName: String,
        advertisement: LoomPeerAdvertisement,
        onSession: @escaping @Sendable (LoomSession) -> Void
    ) async throws -> UInt16 {
        advertisingServiceName = serviceName

        guard configuration.enableBonjour else {
            let directListener = LoomDirectListener(
                transportKind: .tcp,
                enablePeerToPeer: configuration.enablePeerToPeer
            )
            let port = try await directListener.start(port: configuration.controlPort) { connection in
                onSession(LoomSession(connection: connection))
            }
            directListeners[.tcp] = directListener
            directListenerPorts[.tcp] = port
            publishedAdvertisement = Self.advertisement(
                advertisement,
                withDirectTransportPorts: [.tcp: port],
                serviceName: serviceName
            )
            return port
        }

        let advertiser = BonjourAdvertiser(
            serviceName: serviceName,
            advertisement: advertisement,
            serviceType: configuration.serviceType,
            enablePeerToPeer: configuration.enablePeerToPeer
        )
        self.advertiser = advertiser
        let port = try await advertiser.start(port: configuration.controlPort) { connection in
            onSession(LoomSession(connection: connection))
        }
        publishedAdvertisement = Self.advertisement(
            advertisement,
            withDirectTransportPorts: [.tcp: port],
            serviceName: serviceName
        )
        return port
    }

    public func stopAdvertising() async {
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
    }

    public func updateAdvertisement(_ advertisement: LoomPeerAdvertisement) async {
        // Preserve Loom-managed direct transport ports when the caller provides
        // an advertisement without them (e.g. Mirage updating metadata only).
        var ports = directListenerPorts
        if let bonjourPort = await advertiser?.port {
            ports[.tcp] = bonjourPort
        }
        let merged = Self.advertisement(
            advertisement,
            withDirectTransportPorts: ports,
            serviceName: advertisingServiceName
        )
        publishedAdvertisement = merged
        await advertiser?.updateAdvertisement(merged)
    }

    public func makeSession(connection: NWConnection) -> LoomSession {
        LoomSession(connection: connection)
    }

    public func makeAuthenticatedSession(
        connection: NWConnection,
        role: LoomSessionRole,
        transportKind: LoomTransportKind
    ) -> LoomAuthenticatedSession {
        LoomAuthenticatedSession(
            rawSession: LoomSession(connection: connection),
            role: role,
            transportKind: transportKind
        )
    }

    public func makeConnection(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        enablePeerToPeer: Bool? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        requiredLocalPort: UInt16? = nil
    ) throws -> NWConnection {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: transportKind,
            enablePeerToPeer: enablePeerToPeer ?? configuration.enablePeerToPeer,
            requiredInterfaceType: requiredInterfaceType,
            quicALPN: configuration.quicALPN
        )
        if let requiredLocalPort, let port = NWEndpoint.Port(rawValue: requiredLocalPort) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: port)
            parameters.allowLocalEndpointReuse = true
        }
        return NWConnection(to: endpoint, using: parameters)
    }

    public func connect(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        hello: LoomSessionHelloRequest,
        encryptionPolicy: LoomSessionEncryptionPolicy = .required,
        enablePeerToPeer: Bool? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        requiredLocalPort: UInt16? = nil,
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
            let conn = try makeConnection(
                to: target,
                using: transportKind,
                enablePeerToPeer: enablePeerToPeer,
                requiredInterfaceType: requiredInterfaceType,
                requiredLocalPort: requiredLocalPort
            )
            let sess = makeAuthenticatedSession(
                connection: conn,
                role: .initiator,
                transportKind: transportKind
            )
            await sess.setOnTrustPending(onTrustPending)
            await sess.setOnBootstrapProgress(onBootstrapProgress)
            return try await withTaskCancellationHandler {
                _ = try await sess.start(
                    localHello: hello,
                    identityManager: identityManager,
                    trustProvider: trustProvider,
                    encryptionPolicy: encryptionPolicy,
                    queue: queue
                )
                return sess
            } onCancel: {
                conn.cancel()
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
            let port = try await startAdvertising(
                serviceName: serviceName,
                advertisement: baseHello.advertisement
            ) { [weak self] rawSession in
                guard let self else { return }
                let session = LoomAuthenticatedSession(rawSession: rawSession, role: .receiver, transportKind: .tcp)
                Task {
                    do {
                        let hello = try await helloProvider()
                        _ = try await session.start(
                            localHello: hello,
                            identityManager: identityManager,
                            trustProvider: self.trustProvider,
                            encryptionPolicy: encryptionPolicy
                        )
                        onSession(session)
                    } catch {
                        LoomLogger.session(
                            "Authenticated tcp listener session failed for \(serviceName): \(error)"
                        )
                        await session.cancel()
                    }
                }
            }

            var ports: [LoomTransportKind: UInt16] = [.tcp: port]
            await updateAdvertisement(
                Self.advertisement(
                    baseHello.advertisement,
                    withDirectTransportPorts: ports,
                    serviceName: advertisingServiceName
                )
            )

            // Start a separate UDP listener for actual session transport.
            // The Bonjour TCP listener above is only for discovery/permissions —
            // NWListener with Bonjour service registration doesn't accept
            // application-layer UDP datagrams.
            if configuration.enabledDirectTransports.contains(.udp) {
                let udpListener = LoomDirectListener(
                    transportKind: .udp,
                    enablePeerToPeer: configuration.enablePeerToPeer
                )
                let udpPort = try await udpListener.start(port: configuration.udpPort) { [weak self] connection in
                    guard let self else { return }
                    let session = LoomAuthenticatedSession(
                        rawSession: LoomSession(connection: connection),
                        role: .receiver,
                        transportKind: .udp
                    )
                    Task {
                        do {
                            let hello = try await helloProvider()
                            _ = try await session.start(
                                localHello: hello,
                                identityManager: identityManager,
                                trustProvider: self.trustProvider,
                                encryptionPolicy: encryptionPolicy
                            )
                            onSession(session)
                        } catch {
                            LoomLogger.session(
                                "Authenticated udp listener session failed for \(serviceName): \(error)"
                            )
                            await session.cancel()
                        }
                    }
                }
                directListeners[.udp] = udpListener
                directListenerPorts[.udp] = udpPort
                ports[.udp] = udpPort
                await updateAdvertisement(
                    Self.advertisement(
                        baseHello.advertisement,
                        withDirectTransportPorts: ports,
                        serviceName: advertisingServiceName
                    )
                )
            }

            guard configuration.enabledDirectTransports.contains(.quic) else {
                try await startOverlayProbeServer(serviceName: serviceName)
                return ports
            }

            let quicListener = LoomDirectListener(
                transportKind: .quic,
                enablePeerToPeer: configuration.enablePeerToPeer,
                quicALPN: configuration.quicALPN
            )
            let requestedQUICPort = configuration.quicPort
            let quicPort = try await quicListener.start(port: requestedQUICPort) { [weak self] connection in
                guard let self else { return }
                let session = LoomAuthenticatedSession(
                    rawSession: LoomSession(connection: connection),
                    role: .receiver,
                    transportKind: .quic
                )
                Task {
                    do {
                        let hello = try await helloProvider()
                        _ = try await session.start(
                            localHello: hello,
                            identityManager: identityManager,
                            trustProvider: self.trustProvider,
                            encryptionPolicy: encryptionPolicy
                        )
                        onSession(session)
                    } catch {
                        LoomLogger.session(
                            "Authenticated quic listener session failed for \(serviceName): \(error)"
                        )
                        await session.cancel()
                    }
                }
            }
            directListeners[.quic] = quicListener
            directListenerPorts[.quic] = quicPort
            ports[.quic] = quicPort
            await updateAdvertisement(
                Self.advertisement(
                    baseHello.advertisement,
                    withDirectTransportPorts: ports,
                    serviceName: advertisingServiceName
                )
            )
            try await startOverlayProbeServer(serviceName: serviceName)
            return ports
        } catch {
            await stopAdvertising()
            throw error
        }
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

public final class LoomSession: @unchecked Sendable, Hashable {
    public let connection: NWConnection

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public var endpoint: NWEndpoint {
        connection.endpoint
    }

    public func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    public func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: minimumIncompleteLength,
            maximumLength: maximumLength,
            completion: completion
        )
    }

    public func send(content: Data?, completion: NWConnection.SendCompletion) {
        connection.send(content: content, completion: completion)
    }

    public func setStateUpdateHandler(_ handler: @escaping @Sendable (NWConnection.State) -> Void) {
        connection.stateUpdateHandler = handler
    }

    public static func == (lhs: LoomSession, rhs: LoomSession) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
