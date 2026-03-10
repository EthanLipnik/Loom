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
    private var directListeners: [LoomTransportKind: LoomDirectListener] = [:]

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
            discovery.enablePeerToPeer = configuration.enablePeerToPeer
            if let localDeviceID {
                discovery.localDeviceID = localDeviceID
            }
            return discovery
        }

        let discovery = LoomDiscovery(
            serviceType: configuration.serviceType,
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
        let advertiser = BonjourAdvertiser(
            serviceName: serviceName,
            advertisement: advertisement,
            serviceType: configuration.serviceType,
            enablePeerToPeer: configuration.enablePeerToPeer
        )
        self.advertiser = advertiser
        return try await advertiser.start(port: configuration.controlPort) { connection in
            onSession(LoomSession(connection: connection))
        }
    }

    public func stopAdvertising() async {
        await advertiser?.stop()
        advertiser = nil
        for listener in directListeners.values {
            await listener.stop()
        }
        directListeners.removeAll()
    }

    public func updateAdvertisement(_ advertisement: LoomPeerAdvertisement) async {
        await advertiser?.updateAdvertisement(advertisement)
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
        using transportKind: LoomTransportKind
    ) throws -> NWConnection {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: transportKind,
            enablePeerToPeer: configuration.enablePeerToPeer
        )
        return NWConnection(to: endpoint, using: parameters)
    }

    public func connect(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        hello: LoomSessionHelloRequest,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) async throws -> LoomAuthenticatedSession {
        let connection = try makeConnection(to: endpoint, using: transportKind)
        let identityManager = self.identityManager ?? LoomIdentityManager.shared
        let session = makeAuthenticatedSession(
            connection: connection,
            role: .initiator,
            transportKind: transportKind
        )
        _ = try await session.start(
            localHello: hello,
            identityManager: identityManager,
            trustProvider: trustProvider,
            queue: queue
        )
        return session
    }

    public func startAuthenticatedAdvertising(
        serviceName: String,
        helloProvider: @escaping @Sendable () async throws -> LoomSessionHelloRequest,
        onSession: @escaping @Sendable (LoomAuthenticatedSession) -> Void
    ) async throws -> [LoomTransportKind: UInt16] {
        let identityManager = self.identityManager ?? LoomIdentityManager.shared
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
                        trustProvider: self.trustProvider
                    )
                    onSession(session)
                } catch {
                    await session.cancel()
                }
            }
        }

        var ports: [LoomTransportKind: UInt16] = [.tcp: port]
        await updateAdvertisement(
            Self.advertisement(
                baseHello.advertisement,
                withDirectTransportPorts: ports
            )
        )
        guard configuration.enabledDirectTransports.contains(.quic) else {
            return ports
        }

        let quicListener = LoomDirectListener(
            transportKind: .quic,
            enablePeerToPeer: configuration.enablePeerToPeer
        )
        let requestedQUICPort = configuration.quicPort == 0 ? port : configuration.quicPort
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
                        trustProvider: self.trustProvider
                    )
                    onSession(session)
                } catch {
                    await session.cancel()
                }
            }
        }
        directListeners[.quic] = quicListener
        ports[.quic] = quicPort
        await updateAdvertisement(
            Self.advertisement(
                baseHello.advertisement,
                withDirectTransportPorts: ports
            )
        )
        return ports
    }

    private static func advertisement(
        _ base: LoomPeerAdvertisement,
        withDirectTransportPorts ports: [LoomTransportKind: UInt16]
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
