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

    public init(
        configuration: LoomNetworkConfiguration = .default,
        identityManager: LoomIdentityManager? = LoomIdentityManager.shared,
        trustProvider: (any LoomTrustProvider)? = nil
    ) {
        self.configuration = configuration
        self.identityManager = identityManager
        self.trustProvider = trustProvider
    }

    public func makeDiscovery() -> LoomDiscovery {
        if let discovery {
            discovery.enablePeerToPeer = configuration.enablePeerToPeer
            return discovery
        }

        let discovery = LoomDiscovery(
            serviceType: configuration.serviceType,
            enablePeerToPeer: configuration.enablePeerToPeer
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
    }

    public func updateAdvertisement(_ advertisement: LoomPeerAdvertisement) async {
        await advertiser?.updateAdvertisement(advertisement)
    }

    public func makeSession(connection: NWConnection) -> LoomSession {
        LoomSession(connection: connection)
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
