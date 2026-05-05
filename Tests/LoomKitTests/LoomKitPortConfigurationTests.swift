//
//  LoomKitPortConfigurationTests.swift
//  LoomKit
//
//  Created by Codex on 5/5/26.
//

@testable import Loom
@testable import LoomKit
import Testing

@Suite("LoomKit Port Configuration")
struct LoomKitPortConfigurationTests {
    @Test("Default LoomKit overlay probe port follows Loom's default")
    func defaultOverlayProbePortFollowsLoomDefault() {
        #expect(LoomKitPortConfiguration.default.overlayProbePort == Loom.defaultOverlayProbePort)
    }

    @MainActor
    @Test("Container applies LoomKit overlay probe default when overlay configuration omits the port")
    func containerAppliesLoomKitOverlayProbeDefault() throws {
        let container = try LoomContainer(
            for: LoomContainerConfiguration(
                serviceName: "Overlay Host",
                overlayDirectory: LoomOverlayDirectoryConfiguration(
                    seedProvider: { [] }
                )
            )
        )

        #expect(container.configuration.overlayDirectory?.probePort == Loom.defaultOverlayProbePort)
    }

    @MainActor
    @Test("Container preserves explicit LoomKit port overrides")
    func containerPreservesExplicitPortOverrides() throws {
        let ports = LoomKitPortConfiguration(
            tcpPort: 41_001,
            udpPort: 41_002,
            quicPort: 41_003,
            overlayProbePort: 41_004
        )
        let container = try LoomContainer(
            for: LoomContainerConfiguration(
                serviceName: "Custom Port Host",
                overlayDirectory: LoomOverlayDirectoryConfiguration(
                    seedProvider: { [] }
                ),
                ports: ports
            )
        )

        #expect(container.configuration.ports == ports)
        #expect(container.configuration.overlayDirectory?.probePort == ports.overlayProbePort)
    }

    @MainActor
    @Test("Container preserves an explicit overlay directory probe port")
    func containerPreservesExplicitOverlayDirectoryProbePort() throws {
        let container = try LoomContainer(
            for: LoomContainerConfiguration(
                serviceName: "Explicit Overlay Host",
                overlayDirectory: LoomOverlayDirectoryConfiguration(
                    probePort: 41_005,
                    seedProvider: { [] }
                )
            )
        )

        #expect(container.configuration.overlayDirectory?.probePort == 41_005)
    }
}
