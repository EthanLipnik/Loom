//
//  LoomKitSmokeTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

@testable import LoomKit
import Testing

@Suite("LoomKit Smoke Tests")
struct LoomKitSmokeTests {
    @MainActor
    @Test("Container creates a main context")
    func containerCreatesMainContext() throws {
        let container = try LoomContainer(
            for: LoomContainerConfiguration(
                serviceName: "Test Device"
            )
        )

        #expect(container.mainContext.isRunning == false)
        #expect(container.mainContext.peers.isEmpty)
    }
}
