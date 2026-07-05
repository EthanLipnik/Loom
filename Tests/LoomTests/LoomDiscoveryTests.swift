//
//  LoomDiscoveryTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import Loom
import Foundation
import Network
import Testing

@Suite("Loom Discovery")
struct LoomDiscoveryTests {
    @Test("Discovered interfaces identify AWDL as peer-to-peer")
    func discoveredInterfaceIdentifiesAwdl() {
        let discoveredInterface = LoomDiscoveredInterface(
            name: "awdl0",
            type: .other,
            index: 12
        )

        #expect(discoveredInterface.isPeerToPeer)
        #expect(discoveredInterface.kind == .awdl)
        #expect(discoveredInterface.proximityPriority == 1)
    }

    @Test("Discovered interfaces rank proximity candidates before ordinary Wi-Fi")
    func discoveredInterfaceRanksProximityCandidates() {
        let interfaces = [
            LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
            LoomDiscoveredInterface(name: "bridge100", type: .other, index: 14),
            LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            LoomDiscoveredInterface(name: "en3", type: .wiredEthernet, index: 10),
            LoomDiscoveredInterface(name: "llw0", type: .other, index: 13),
            LoomDiscoveredInterface(name: "anpi0", type: .other, index: 9),
        ]

        let ranked = interfaces
            .filter(\.isProximityPreferred)
            .sorted {
                ($0.proximityPriority ?? Int.max) < ($1.proximityPriority ?? Int.max)
            }

        #expect(ranked.map(\.name) == ["anpi0", "awdl0", "llw0", "en3", "bridge100"])
        #expect(!interfaces[0].isProximityPreferred)
        #expect(interfaces[5].kind == .applePrivateNCM)
        #expect(interfaces[5].proximityPriority == 0)
    }

    @MainActor
    @Test("Discovery stays stopped when Bonjour is disabled")
    func discoveryDoesNotStartWhenBonjourIsDisabled() {
        let discovery = LoomDiscovery(enableBonjour: false)

        discovery.startDiscovery()

        #expect(discovery.isSearching == false)
        #expect(discovery.isBrowserReady == false)
        #expect(discovery.discoveredPeers.isEmpty)

        discovery.refresh()

        #expect(discovery.isSearching == false)
        #expect(discovery.isBrowserReady == false)
        #expect(discovery.discoveredPeers.isEmpty)
    }

    @Test("TXT record monitor stop completion waits for worker teardown")
    func txtRecordMonitorStopCompletionWaitsForWorkerTeardown() async throws {
        for _ in 0..<5 {
            let monitor = BonjourTXTRecordMonitor(
                serviceType: "_loom-test._tcp.",
                enablePeerToPeer: false
            )

            monitor.start()

            let completedAfterWorkerFinished = try await withTimeout(.seconds(2)) {
                await withCheckedContinuation { continuation in
                    monitor.stop {
                        continuation.resume(returning: monitor.hasFinishedWorkerThreadForTesting)
                    }
                }
            }

            #expect(completedAfterWorkerFinished)
        }
    }

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
    @Test("Discovery suppresses duplicate semantic peer snapshots")
    func discoverySuppressesDuplicateNotifications() throws {
        let discovery = LoomDiscovery()
        let peer = makePeer(
            id: UUID(),
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

        var notificationCount = 0
        let token = discovery.addPeersChangedObserver { _ in
            notificationCount += 1
        }
        defer {
            discovery.removePeersChangedObserver(token)
        }

        discovery.upsertPeerForTesting(peer)
        discovery.upsertPeerForTesting(peer)

        #expect(notificationCount == 1)
    }

    @MainActor
    @Test("Discovery prefers a transport-capable candidate over an equivalent candidate without direct transports")
    func discoveryPrefersTransportCapableCandidate() throws {
        let deviceID = UUID()
        let discovery = LoomDiscovery()
        let metadataOnlyPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 5500,
            directTransports: []
        )
        let transportPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 6600,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: 6600,
                    pathKind: .wifi
                ),
            ]
        )

        discovery.upsertPeerForTesting(metadataOnlyPeer)
        discovery.upsertPeerForTesting(transportPeer)

        let preferredPeer = try #require(discovery.discoveredPeers.first)
        #expect(preferredPeer.endpoint.debugDescription == transportPeer.endpoint.debugDescription)
        #expect(preferredPeer.advertisement.directTransports == transportPeer.advertisement.directTransports)
    }

    @MainActor
    @Test("Discovery merges interfaces from same-device Bonjour candidates")
    func discoveryMergesInterfacesFromSameDeviceCandidates() throws {
        let deviceID = UUID()
        let discovery = LoomDiscovery()
        let wifiPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 6600,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: 6600,
                    pathKind: .wifi
                ),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
                LoomDiscoveredInterface(name: "anpi0", type: .other, index: 9),
            ]
        )
        let awdlPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 7700,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .tcp,
                    port: 7700,
                    pathKind: .awdl
                ),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        discovery.upsertPeerForTesting(wifiPeer)
        discovery.upsertPeerForTesting(awdlPeer)

        let preferredPeer = try #require(discovery.discoveredPeers.first)
        #expect(preferredPeer.endpoint.debugDescription == wifiPeer.endpoint.debugDescription)
        #expect(preferredPeer.discoveredInterfaces.map(\.name) == ["anpi0", "awdl0", "en0"])
    }

    @MainActor
    @Test("Discovery merges resolved addresses from same-device Bonjour candidates")
    func discoveryMergesResolvedAddressesFromSameDeviceCandidates() throws {
        let deviceID = UUID()
        let discovery = LoomDiscovery()
        let wifiAddress = try #require(IPv4Address("192.168.1.50"))
        let duplicateWifiAddress = try #require(IPv4Address("192.168.1.50"))
        let awdlAddress = try #require(IPv6Address("fe80::1%awdl0"))
        let anpiAddress = try #require(IPv6Address("fe80::2%anpi0"))
        let wifiPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 6600,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: 6600,
                    pathKind: .wifi
                ),
            ],
            resolvedAddresses: [
                .ipv4(wifiAddress),
                .ipv6(anpiAddress),
            ]
        )
        let awdlPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 7700,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .tcp,
                    port: 7700,
                    pathKind: .awdl
                ),
            ],
            resolvedAddresses: [
                .ipv6(awdlAddress),
                .ipv4(duplicateWifiAddress),
            ]
        )

        discovery.upsertPeerForTesting(wifiPeer)
        discovery.upsertPeerForTesting(awdlPeer)

        let preferredPeer = try #require(discovery.discoveredPeers.first)
        #expect(preferredPeer.endpoint.debugDescription == wifiPeer.endpoint.debugDescription)
        #expect(preferredPeer.resolvedAddresses.map(\.debugDescription) == [
            NWEndpoint.Host.ipv4(wifiAddress).debugDescription,
            NWEndpoint.Host.ipv6(anpiAddress).debugDescription,
            NWEndpoint.Host.ipv6(awdlAddress).debugDescription,
        ])
        #expect(preferredPeer.resolvedServiceAddresses.map(\.interfaceName) == [
            nil,
            "anpi0",
            "awdl0",
        ])
        #expect(preferredPeer.resolvedServiceAddresses.map(\.interfaceKind) == [
            nil,
            .applePrivateNCM,
            .awdl,
        ])
    }

    @MainActor
    @Test("Discovery does not bind unscoped addresses to separate proximity interface hints")
    func discoveryDoesNotBindUnscopedAddressesToSeparateProximityInterfaceHints() throws {
        let deviceID = UUID()
        let discovery = LoomDiscovery()
        let wifiAddress = try #require(IPv4Address("192.168.1.50"))
        let peer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 6600,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: 6600,
                    pathKind: .wifi
                ),
            ],
            resolvedAddresses: [.ipv4(wifiAddress)],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "anpi0", type: .other, index: 9),
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
            ]
        )

        discovery.upsertPeerForTesting(peer)

        let discoveredPeer = try #require(discovery.discoveredPeers.first)
        #expect(discoveredPeer.resolvedServiceAddresses.map(\.host) == [.ipv4(wifiAddress)])
        #expect(discoveredPeer.resolvedServiceAddresses.map(\.interfaceName) == [nil])
        #expect(discoveredPeer.resolvedServiceAddresses.map(\.interfaceKind) == [nil])
    }

    @MainActor
    @Test("Discovery drops resolved addresses from removed same-device candidates")
    func discoveryRemovesResolvedAddressesFromRemovedSameDeviceCandidate() throws {
        let deviceID = UUID()
        let discovery = LoomDiscovery()
        let wifiAddress = try #require(IPv4Address("192.168.1.50"))
        let awdlAddress = try #require(IPv6Address("fe80::1%awdl0"))
        let wifiPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 6600,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: 6600,
                    pathKind: .wifi
                ),
            ],
            resolvedAddresses: [.ipv4(wifiAddress)],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
            ]
        )
        let awdlPeer = makePeer(
            id: deviceID,
            name: "Studio Mac",
            endpointPort: 7700,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .tcp,
                    port: 7700,
                    pathKind: .awdl
                ),
            ],
            resolvedAddresses: [.ipv6(awdlAddress)],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        discovery.upsertPeerForTesting(wifiPeer)
        discovery.upsertPeerForTesting(awdlPeer)
        discovery.removePeerForTesting(endpoint: awdlPeer.endpoint)

        let fallbackPeer = try #require(discovery.discoveredPeers.first)
        #expect(fallbackPeer.endpoint.debugDescription == wifiPeer.endpoint.debugDescription)
        #expect(fallbackPeer.resolvedAddresses.map(\.debugDescription) == [
            NWEndpoint.Host.ipv4(wifiAddress).debugDescription,
        ])
        #expect(fallbackPeer.discoveredInterfaces.map(\.name) == ["en0"])

        discovery.removePeerForTesting(endpoint: wifiPeer.endpoint)
        #expect(discovery.discoveredPeers.isEmpty)
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
        let awdlInterface = LoomDiscoveredInterface(
            name: "awdl0",
            type: .other,
            index: 12
        )
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
            ),
            discoveredInterfaces: [awdlInterface]
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
        #expect(alphaPeer.discoveredInterfaces == [awdlInterface])
    }

    @MainActor
    @Test("Discovery waits for Bonjour TXT identity before publishing peers")
    func discoveryWaitsForBonjourTXTIdentityBeforePublishingPeers() throws {
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

        #expect(discovery.discoveredPeers.isEmpty)

        discovery.upsertBonjourPeerForTesting(
            peerName: peerName,
            endpoint: endpoint,
            txtRecord: LoomPeerAdvertisement(deviceType: .mac).toTXTRecord()
        )

        #expect(discovery.discoveredPeers.isEmpty)

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
    }

    @MainActor
    @Test("Discovery removes Bonjour peers when TXT identity disappears")
    func discoveryRemovesBonjourPeersWhenTXTIdentityDisappears() throws {
        let discovery = LoomDiscovery()
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: 8801)!
        )
        let deviceID = UUID()
        let txtRecord = LoomPeerAdvertisement(
            deviceID: deviceID,
            deviceType: .mac
        ).toTXTRecord()

        discovery.upsertBonjourPeerForTesting(
            peerName: "Studio Mac",
            endpoint: endpoint,
            txtRecord: txtRecord
        )

        #expect(discovery.discoveredPeers.count == 1)

        discovery.upsertBonjourPeerForTesting(
            peerName: "Studio Mac",
            endpoint: endpoint,
            txtRecord: [:]
        )

        #expect(discovery.discoveredPeers.isEmpty)
    }

    @MainActor
    @Test("Discovery preserves transport hints when a later Bonjour TXT update omits them")
    func discoveryPreservesTransportHintsWhenLaterTXTUpdateOmitsThem() throws {
        let discovery = LoomDiscovery()
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: 8802)!
        )
        let deviceID = UUID()
        let udpTransport = LoomDirectTransportAdvertisement(
            transportKind: .udp,
            port: 6000,
            pathKind: .wifi
        )
        let quicTransport = LoomDirectTransportAdvertisement(
            transportKind: .quic,
            port: 6001,
            pathKind: .wifi
        )
        let tcpTransport = LoomDirectTransportAdvertisement(
            transportKind: .tcp,
            port: 6002,
            pathKind: .wifi
        )

        discovery.upsertBonjourPeerForTesting(
            peerName: "Studio Mac",
            endpoint: endpoint,
            txtRecord: LoomPeerAdvertisement(
                deviceID: deviceID,
                deviceType: .mac,
                directTransports: [udpTransport, quicTransport, tcpTransport],
                metadata: ["loom.role": "host"]
            ).toTXTRecord()
        )

        discovery.upsertBonjourPeerForTesting(
            peerName: "Studio Mac",
            endpoint: endpoint,
            txtRecord: LoomPeerAdvertisement(
                deviceID: deviceID,
                deviceType: .mac,
                metadata: ["loom.role": "host"]
            ).toTXTRecord()
        )

        let discoveredPeer = try #require(discovery.discoveredPeers.first)
        #expect(discoveredPeer.advertisement.directTransports == [
            tcpTransport,
            quicTransport,
            udpTransport,
        ])
    }

    @MainActor
    @Test("Testing upsert preserves missing advertised device ID")
    func testingUpsertPreservesMissingAdvertisedDeviceID() throws {
        let discovery = LoomDiscovery()
        let fallbackID = UUID()
        let awdlInterface = LoomDiscoveredInterface(
            name: "awdl0",
            type: .other,
            index: 12
        )
        let peer = LoomPeer(
            id: fallbackID,
            name: "Fallback Host",
            deviceType: .mac,
            endpoint: .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: 9901)!
            ),
            advertisement: LoomPeerAdvertisement(
                deviceID: nil,
                deviceType: .mac
            ),
            discoveredInterfaces: [awdlInterface]
        )

        discovery.upsertPeerForTesting(peer)

        let discoveredPeer = try #require(discovery.discoveredPeers.first)
        #expect(discoveredPeer.deviceID == fallbackID)
        #expect(discoveredPeer.advertisement.deviceID == nil)
        #expect(discoveredPeer.discoveredInterfaces == [awdlInterface])
    }

    @MainActor
    private func makePeer(
        id: UUID,
        name: String,
        endpointPort: UInt16,
        directTransports: [LoomDirectTransportAdvertisement],
        resolvedAddresses: [NWEndpoint.Host] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
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
            ),
            resolvedAddresses: resolvedAddresses,
            discoveredInterfaces: discoveredInterfaces
        )
    }
}

private enum LoomDiscoveryTestTimeout: Error {
    case timedOut
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LoomDiscoveryTestTimeout.timedOut
        }

        guard let result = try await group.next() else {
            throw LoomDiscoveryTestTimeout.timedOut
        }
        group.cancelAll()
        return result
    }
}
