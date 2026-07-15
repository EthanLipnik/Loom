//
//  LoomNetworkFrameworkAdapterTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

@testable import Loom
import Network
import Testing

@Suite("Network.framework Adapters")
struct LoomNetworkFrameworkAdapterTests {
    @Test("Host-port endpoints round-trip without changing address scope")
    func hostPortEndpointRoundTrip() throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("fe80::1%en7"),
            port: try #require(NWEndpoint.Port(rawValue: 38_447))
        )

        let backendEndpoint = try #require(LoomNetworkEndpoint(endpoint))
        let roundTripped = try #require(backendEndpoint.nwEndpoint)

        #expect(String(describing: roundTripped) == String(describing: endpoint))
    }

    @Test("DNS-SD service identity round-trips when no opaque interface is required")
    func serviceEndpointRoundTrip() throws {
        let endpoint = NWEndpoint.service(
            name: "Studio Mac",
            type: "_loom._tcp",
            domain: "local.",
            interface: nil
        )

        let backendEndpoint = try #require(LoomNetworkEndpoint(endpoint))
        let roundTripped = try #require(backendEndpoint.nwEndpoint)

        #expect(roundTripped == endpoint)
    }

    @Test("Known service classes map in both directions")
    func serviceClassRoundTrip() {
        let serviceClasses: [NWParameters.ServiceClass] = [
            .bestEffort,
            .background,
            .interactiveVideo,
            .interactiveVoice,
            .responsiveData,
            .signaling,
        ]

        for serviceClass in serviceClasses {
            let backendServiceClass = LoomNetworkServiceClass(serviceClass)
            #expect(backendServiceClass.nwServiceClass == serviceClass)
        }
    }

    @Test("Released configuration property projects neutral stored service class")
    func configurationServiceClassProjection() {
        var configuration = LoomNetworkConfiguration(
            backendDirectDatagramServiceClass: .signaling
        )

        #expect(configuration.directDatagramServiceClass == .signaling)
        configuration.directDatagramServiceClass = .interactiveVoice
        #expect(configuration.backendDirectDatagramServiceClass == .interactiveVoice)
    }

    @Test("Portable peer storage retains released Network.framework projections")
    func peerProjection() throws {
        let endpoint = LoomNetworkEndpoint.hostPort(host: "fe80::4%en7", port: 38_447)
        let peer = LoomPeer(
            id: UUID(),
            name: "Studio Mac",
            deviceType: .mac,
            backendEndpoint: endpoint,
            advertisement: LoomPeerAdvertisement(),
            backendResolvedAddresses: ["192.0.2.8", "fe80::4%en7"],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en7", backendType: .wiredEthernet, index: 7),
            ]
        )

        #expect(LoomNetworkEndpoint(peer.endpoint) == endpoint)
        #expect(peer.resolvedAddresses.map(String.init(describing:)) == ["192.0.2.8", "fe80::4%en7"])
        #expect(peer.discoveredInterfaces.first?.type == .wiredEthernet)
    }

    @Test("Session path projection retains observable route semantics")
    func sessionPathProjection() throws {
        let localEndpoint = NWEndpoint.hostPort(
            host: "192.0.2.4",
            port: try #require(NWEndpoint.Port(rawValue: 50_000))
        )
        let remoteEndpoint = NWEndpoint.hostPort(
            host: "192.0.2.8",
            port: try #require(NWEndpoint.Port(rawValue: 38_447))
        )
        let snapshot = LoomSessionNetworkPathSnapshot(
            status: .satisfied,
            interfaceNames: ["en0", "bridge0"],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: false,
            usesWiFi: true,
            usesWiredEthernet: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        )

        #expect(snapshot.backendPath.status == .satisfied)
        #expect(snapshot.backendPath.interfaces.map(\.type) == [.other, .other])
        #expect(snapshot.backendPath.usesWiFi)
        #expect(snapshot.backendPath.usesWiredEthernet)
        #expect(snapshot.backendPath.localEndpoint == LoomNetworkEndpoint(localEndpoint))
        #expect(snapshot.backendPath.remoteEndpoint == LoomNetworkEndpoint(remoteEndpoint))
    }

    @Test("Portable session path stores endpoints without Network.framework")
    func portableSessionPathStorage() {
        let snapshot = LoomSessionNetworkPathSnapshot(
            status: .satisfied,
            interfaceNames: ["ethernet0"],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: false,
            usesWiFi: false,
            usesWiredEthernet: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            backendLocalEndpoint: .hostPort(host: "192.0.2.4", port: 50_000),
            backendRemoteEndpoint: .hostPort(host: "192.0.2.8", port: 38_447)
        )

        #expect(snapshot.backendLocalEndpoint == LoomNetworkEndpoint.hostPort(host: "192.0.2.4", port: 50_000))
        #expect(snapshot.backendRemoteEndpoint == LoomNetworkEndpoint.hostPort(host: "192.0.2.8", port: 38_447))
        #expect(snapshot.localEndpoint.map(String.init(describing:)) == "192.0.2.4:50000")
        #expect(snapshot.remoteEndpoint.map(String.init(describing:)) == "192.0.2.8:38447")
    }

    @Test("Datagram receive diagnostics separate callback, re-arm, and resume timing")
    func datagramReceiveDiagnosticsSeparateTimingBoundaries() {
        let diagnostics = LoomNetworkFrameworkDatagramReceiveDiagnostics()

        diagnostics.recordRegistration(at: 10.000)
        diagnostics.recordCallback(at: 10.008)
        diagnostics.recordConsumerResume(
            afterCallbackAt: 10.008,
            strategy: .direct,
            at: 10.009
        )
        diagnostics.recordRegistration(at: 10.011)
        diagnostics.recordCallback(at: 10.020)
        diagnostics.recordConsumerResume(
            afterCallbackAt: 10.020,
            strategy: .direct,
            at: 10.024
        )

        let snapshot = diagnostics.snapshot()
        #expect(snapshot.callbackCount == 2)
        #expect(snapshot.callbackGapP99Ms == 16.7)
        #expect(snapshot.callbackGapMaxMs >= 11.9)
        #expect(snapshot.callbackGapMaxMs <= 12.1)
        #expect(snapshot.rearmGapP99Ms == 4)
        #expect(snapshot.rearmGapMaxMs >= 2.9)
        #expect(snapshot.rearmGapMaxMs <= 3.1)
        #expect(snapshot.armToCallbackP99Ms == 16.7)
        #expect(snapshot.armToCallbackMaxMs >= 8.9)
        #expect(snapshot.armToCallbackMaxMs <= 9.1)
        #expect(snapshot.callbackToResumeP99Ms == 4)
        #expect(snapshot.callbackToResumeMaxMs >= 3.9)
        #expect(snapshot.callbackToResumeMaxMs <= 4.1)
    }
}
