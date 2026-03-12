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
    @Test("Discovery expands one shared host advertisement into multiple app-shaped peers")
    func discoveryExpandsSharedHostCatalog() throws {
        let deviceID = UUID()
        let discovery = LoomDiscovery()
        let catalog = LoomHostCatalog(
            entries: [
                LoomHostCatalogEntry(
                    appID: "com.example.alpha",
                    displayName: "Alpha",
                    metadata: ["alpha": "1"],
                    supportedFeatures: ["alpha-feature"]
                ),
                LoomHostCatalogEntry(
                    appID: "com.example.beta",
                    displayName: "Beta",
                    metadata: ["beta": "1"],
                    supportedFeatures: ["beta-feature"]
                ),
            ]
        )
        let metadata = try LoomHostCatalogCodec.addingCatalog(catalog, to: [:])
        let peer = LoomPeer(
            id: deviceID,
            name: "Shared Host",
            deviceType: .mac,
            endpoint: .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: 9900)!
            ),
            advertisement: LoomPeerAdvertisement(
                deviceID: deviceID,
                deviceType: .mac,
                metadata: metadata
            )
        )

        discovery.upsertPeerForTesting(peer)

        #expect(discovery.discoveredPeers.count == 2)
        #expect(discovery.discoveredPeers.map(\.id).contains(LoomPeerID(deviceID: deviceID, appID: "com.example.alpha")))
        #expect(discovery.discoveredPeers.map(\.id).contains(LoomPeerID(deviceID: deviceID, appID: "com.example.beta")))

        let alphaPeer = try #require(
            discovery.discoveredPeers.first { $0.appID == "com.example.alpha" }
        )
        #expect(alphaPeer.name == "Alpha")
        #expect(alphaPeer.advertisement.metadata["alpha"] == "1")
        #expect(alphaPeer.advertisement.metadata[LoomHostCatalogCodec.metadataKey] == nil)
    }

    @MainActor
    @Test("Discovery promotes Bonjour peers from fallback identity to advertised metadata")
    func discoveryPromotesBonjourPeersFromFallbackIdentityToAdvertisedMetadata() throws {
        let discovery = LoomDiscovery()
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: 8800)!
        )
        let peerName = "Studio Mac"
        let deviceID = UUID()
        let advertisedTransport = LoomDirectTransportAdvertisement(
            transportKind: .tcp,
            port: 4242,
            pathKind: .wifi
        )
        let advertisedTXTRecord = LoomPeerAdvertisement(
            deviceID: deviceID,
            deviceType: .mac,
            modelIdentifier: "Mac15,9",
            iconName: "macstudio",
            machineFamily: "Mac",
            directTransports: [advertisedTransport],
            metadata: ["loom.role": "host"]
        ).toTXTRecord()

        discovery.upsertBonjourPeerForTesting(
            peerName: peerName,
            endpoint: endpoint,
            txtRecord: [:]
        )

        let fallbackPeer = try #require(discovery.discoveredPeers.first)
        #expect(fallbackPeer.name == peerName)
        #expect(fallbackPeer.deviceType == .unknown)
        #expect(fallbackPeer.deviceID != deviceID)
        #expect(fallbackPeer.advertisement.deviceID == fallbackPeer.deviceID)
        #expect(fallbackPeer.advertisement.modelIdentifier == nil)
        #expect(fallbackPeer.advertisement.iconName == nil)

        discovery.upsertBonjourPeerForTesting(
            peerName: peerName,
            endpoint: endpoint,
            txtRecord: advertisedTXTRecord
        )

        #expect(discovery.discoveredPeers.count == 1)
        let resolvedPeer = try #require(discovery.discoveredPeers.first)
        #expect(resolvedPeer.name == peerName)
        #expect(resolvedPeer.id == LoomPeerID(deviceID: deviceID))
        #expect(resolvedPeer.deviceType == .mac)
        #expect(resolvedPeer.advertisement.deviceID == deviceID)
        #expect(resolvedPeer.advertisement.deviceType == .mac)
        #expect(resolvedPeer.advertisement.modelIdentifier == "Mac15,9")
        #expect(resolvedPeer.advertisement.iconName == "macstudio")
        #expect(resolvedPeer.advertisement.machineFamily == "Mac")
        #expect(resolvedPeer.advertisement.directTransports == [advertisedTransport])
        #expect(resolvedPeer.advertisement.metadata["loom.role"] == "host")
        #expect(discovery.discoveredPeers.map(\.id).contains(fallbackPeer.id) == false)
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
