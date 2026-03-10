//
//  LoomDiscoveryTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

@testable import Loom
import Foundation
import Network
import Testing

@Suite("Loom Discovery")
struct LoomDiscoveryTests {
    @MainActor
    @Test("Discovery deduplicates multiple endpoints for one device and prefers the best transport")
    func discoveryDeduplicatesLogicalPeers() throws {
        let deviceID = UUID()
        let discovery = LoomDiscovery()

        let wifiTCPPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 5500,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .tcp,
                    port: 5500,
                    pathKind: .wifi
                ),
            ]
        )
        let wiredQUICPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 6600,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .quic,
                    port: 6600,
                    pathKind: .wired
                ),
            ]
        )

        var observedSnapshots: [[LoomPeer]] = []
        let token = discovery.addPeersChangedObserver { peers in
            observedSnapshots.append(peers)
        }
        defer {
            discovery.removePeersChangedObserver(token)
        }

        discovery.upsertPeerForTesting(wifiTCPPeer)
        discovery.upsertPeerForTesting(wiredQUICPeer)

        #expect(discovery.discoveredPeers.count == 1)
        let preferredPeer = try #require(discovery.discoveredPeers.first)
        #expect(preferredPeer.id == deviceID)
        #expect(preferredPeer.endpoint.debugDescription == wiredQUICPeer.endpoint.debugDescription)

        discovery.removePeerForTesting(endpoint: wiredQUICPeer.endpoint)

        #expect(discovery.discoveredPeers.count == 1)
        let fallbackPeer = try #require(discovery.discoveredPeers.first)
        #expect(fallbackPeer.endpoint.debugDescription == wifiTCPPeer.endpoint.debugDescription)

        discovery.stopDiscovery()

        #expect(discovery.discoveredPeers.isEmpty)
        #expect(observedSnapshots.last?.isEmpty == true)
    }

    @MainActor
    @Test("Discovery filters the local device identifier from emitted peers")
    func discoveryFiltersLocalDeviceID() {
        let localDeviceID = UUID()
        let discovery = LoomDiscovery(localDeviceID: localDeviceID)

        discovery.upsertPeerForTesting(
            makePeer(
                id: localDeviceID,
                name: "This Device",
                endpointPort: 7700,
                directTransports: []
            )
        )

        #expect(discovery.discoveredPeers.isEmpty)
    }

    @MainActor
    private func makePeer(
        id: UUID,
        name: String,
        endpointPort: UInt16,
        directTransports: [LoomDirectTransportAdvertisement]
    ) -> LoomPeer {
        LoomPeer(
            id: id,
            name: name,
            deviceType: .mac,
            endpoint: .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: endpointPort)!
            ),
            advertisement: LoomPeerAdvertisement(
                deviceID: id,
                deviceType: .mac,
                directTransports: directTransports
            )
        )
    }
}
