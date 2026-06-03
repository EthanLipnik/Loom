//
//  LoomNodeAdvertisementTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/26/26.
//

@testable import Loom
import Foundation
import Network
import Testing

@Suite("Loom Node Advertisement")
struct LoomNodeAdvertisementTests {
    @MainActor
    @Test("Node creates QUIC LoomConnection for QUIC direct transport")
    func nodeCreatesQUICConnectionForQUICTransport() throws {
        let node = LoomNode()
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: 9))
        )

        let connection = try node.makeConnection(
            to: endpoint,
            using: .quic,
            enablePeerToPeer: false
        )

        guard case .quic = connection else {
            Issue.record("Expected LoomConnection.quic for QUIC direct transport.")
            return
        }
    }

    @MainActor
    @Test("TCP-only advertising publishes diagnostics")
    func tcpOnlyAdvertisingPublishesDiagnostics() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                enableBonjour: false,
                enablePeerToPeer: false,
                enabledDirectTransports: []
            ),
            identityManager: LoomIdentityManager(
                service: "loom.tests.advertising.\(UUID().uuidString)",
                synchronizable: false
            )
        )

        let deviceID = UUID()
        let ports = try await node.startAuthenticatedAdvertising(
            serviceName: "Test Host",
            helloProvider: {
                LoomSessionHelloRequest(
                    deviceID: deviceID,
                    deviceName: "Test Host",
                    deviceType: .mac,
                    advertisement: LoomPeerAdvertisement(
                        deviceID: deviceID,
                        deviceType: .mac
                    )
                )
            },
            onSession: { _ in }
        )

        #expect(node.advertisingDiagnostics.state == .advertising)
        #expect(node.advertisingDiagnostics.serviceName == "Test Host")
        #expect(node.advertisingDiagnostics.bonjourPort == nil)
        #expect(node.advertisingDiagnostics.directListenerPorts[.tcp] == ports[.tcp])
        #expect(node.advertisingDiagnostics.lastBonjourFailureDescription == nil)

        await node.stopAdvertising()
        #expect(node.advertisingDiagnostics.state == .idle)
    }

    @Test("Bonjour advertiser recovery delay backs off and caps")
    func bonjourAdvertiserRecoveryDelayBacksOffAndCaps() {
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 1) == .seconds(1))
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 2) == .seconds(2))
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 5) == .seconds(16))
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 10) == .seconds(30))
    }

    @Test("Advertisement leaves hostName unset when no explicit host name is provided")
    func advertisementLeavesHostNameUnsetWithoutExplicitValue() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )

        let updated = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [:],
            serviceName: "Mirage Host"
        )

        #expect(updated.hostName == nil)
    }

    @Test("Advertisement preserves an explicit host name when one is already present")
    func advertisementPreservesExplicitHostName() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac,
            hostName: "existing.local"
        )

        let updated = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [:],
            serviceName: "Mirage Host"
        )

        #expect(updated.hostName == "existing.local")
    }

    @Test("Initial authenticated Bonjour advertisement includes ready direct transports")
    func initialAuthenticatedBonjourAdvertisementIncludesReadyDirectTransports() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )

        let initial = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [
                .udp: 1234,
                .quic: 5678,
            ],
            serviceName: "Mirage Host"
        )

        #expect(Set(initial.directTransports.map(\.transportKind)) == [.udp, .quic])
        #expect(initial.directTransports.contains { $0.transportKind == .tcp } == false)
    }

    @Test("Bonjour TCP update preserves previously advertised direct transports")
    func bonjourTCPUpdatePreservesPreviouslyAdvertisedDirectTransports() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )
        let initial = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [
                .udp: 1234,
                .quic: 5678,
            ],
            serviceName: "Mirage Host"
        )

        let updated = LoomNode.advertisement(
            initial,
            withDirectTransportPorts: [
                .udp: 1234,
                .quic: 5678,
                .tcp: 9012,
            ],
            serviceName: "Mirage Host"
        )

        #expect(Set(updated.directTransports.map(\.transportKind)) == [.tcp, .udp, .quic])
        #expect(updated.directTransports.first { $0.transportKind == .udp }?.port == 1234)
        #expect(updated.directTransports.first { $0.transportKind == .quic }?.port == 5678)
        #expect(updated.directTransports.first { $0.transportKind == .tcp }?.port == 9012)
    }

    @Test("TCP-only Bonjour advertisement gains TCP after service port is known")
    func tcpOnlyBonjourAdvertisementGainsTCPAfterServicePortIsKnown() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )

        let initial = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [:],
            serviceName: "Mirage Host"
        )
        let updated = LoomNode.advertisement(
            initial,
            withDirectTransportPorts: [.tcp: 9012],
            serviceName: "Mirage Host"
        )

        #expect(initial.directTransports.isEmpty)
        #expect(updated.directTransports.map(\.transportKind) == [.tcp])
        #expect(updated.directTransports.first?.port == 9012)
    }
}
