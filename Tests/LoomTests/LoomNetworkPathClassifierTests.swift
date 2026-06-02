//
//  LoomNetworkPathClassifierTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  AWDL transport path classification behavior coverage.
//

@testable import Loom
import Testing

@Suite("Network Path Classifier")
struct LoomNetworkPathClassifierTests {
    @Test("AWDL classification prefers awdl interface signatures over generic other")
    func classifyAwdlPath() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["en0", "awdl0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .awdl)
        #expect(snapshot.isReady)
        #expect(snapshot.signature.localizedStandardContains("kind=awdl"))
    }

    @Test("Apple private proximity interfaces classify as AWDL paths")
    func classifyApplePrivateProximityPaths() {
        let anpiSnapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["anpi0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let apniSnapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["apni0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let llwSnapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["llw0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(anpiSnapshot.kind == .awdl)
        #expect(apniSnapshot.kind == .awdl)
        #expect(llwSnapshot.kind == .awdl)
    }

    @Test("Bridge classification maps to wired")
    func classifyBridgePath() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["bridge100"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .wired)
    }

    @Test("Wi-Fi classification remains stable when AWDL interface is absent")
    func classifyWiFiPath() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["en0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .wifi)
    }

    @Test("Wi-Fi classification wins when AWDL is only an available interface")
    func classifyWiFiPathWithAvailableAwdlInterface() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["awdl0", "en0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .wifi)
        #expect(snapshot.signature.localizedStandardContains("kind=wifi"))
    }

    @Test("Scoped AWDL endpoint wins over Wi-Fi interface flags")
    func scopedAwdlEndpointWinsOverWiFiFlags() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["awdl0", "en0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            localEndpointDescription: "[fe80::1%awdl0]:49152",
            remoteEndpointDescription: "[fe80::2%25awdl0]:49153"
        )

        #expect(snapshot.kind == .awdl)
        #expect(snapshot.signature.localizedStandardContains("kind=awdl"))
        #expect(snapshot.signature.localizedStandardContains("%awdl0"))
    }

    @Test("Scoped AWDL endpoint wins over passive overlay interface")
    func scopedAwdlEndpointWinsOverPassiveOverlayInterface() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["utun4", "awdl0", "en0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            localEndpointDescription: "[fe80::1%awdl0]:49152",
            remoteEndpointDescription: "[fe80::2%25awdl0]:49153"
        )

        #expect(snapshot.kind == .awdl)
        #expect(snapshot.signature.localizedStandardContains("kind=awdl"))
    }

    @Test("Overlay classification prefers utun interfaces over generic other")
    func classifyOverlayPath() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: ["utun4"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .overlay)
        #expect(snapshot.isReady)
        #expect(snapshot.signature.localizedStandardContains("kind=overlay"))
    }

    @Test("Unknown classification applies when no interface hints are present")
    func classifyUnknownPath() {
        let snapshot = LoomNetworkPathClassifier.classify(
            interfaceNames: [],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "unsatisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: false,
            supportsIPv6: false
        )

        #expect(snapshot.kind == .unknown)
        #expect(!snapshot.isReady)
    }
}
