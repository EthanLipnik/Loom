//
//  LoomTrustStoreTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Trust Store", .serialized)
struct LoomTrustStoreTests {
    @MainActor
    @Test("Trust store upserts by device ID instead of appending duplicates")
    func trustStoreUpsertsByDeviceID() throws {
        let suiteName = "com.ethanlipnik.loom.tests.trust.\(UUID().uuidString)"
        defer {
            clearSuite(named: suiteName)
        }

        let deviceID = UUID()
        let originalTrustedAt = Date(timeIntervalSince1970: 1_000)
        let updatedTrustedAt = Date(timeIntervalSince1970: 2_000)

        let store = LoomTrustStore(
            storageKey: "TrustedDevices",
            suiteName: suiteName
        )
        store.addTrustedDevice(
            LoomTrustedDevice(
                id: deviceID,
                name: "Original Name",
                deviceType: .mac,
                trustedAt: originalTrustedAt
            )
        )
        store.addTrustedDevice(
            LoomTrustedDevice(
                id: deviceID,
                name: "Updated Name",
                deviceType: .mac,
                trustedAt: updatedTrustedAt
            )
        )

        #expect(store.trustedDevices.count == 1)
        let trustedDevice = try #require(store.trustedDevices.first)
        #expect(trustedDevice.name == "Updated Name")
        #expect(trustedDevice.trustedAt == updatedTrustedAt)
    }

    @MainActor
    @Test("Trust store persists through a shared suite and reloads deduplicated state")
    func trustStorePersistsThroughSharedSuite() {
        let suiteName = "com.ethanlipnik.loom.tests.shared-trust.\(UUID().uuidString)"
        defer {
            clearSuite(named: suiteName)
        }

        let deviceID = UUID()
        let firstStore = LoomTrustStore(
            storageKey: "TrustedDevices",
            suiteName: suiteName
        )
        firstStore.addTrustedDevice(
            LoomTrustedDevice(
                id: deviceID,
                name: "Shared Mac",
                deviceType: .mac,
                trustedAt: Date()
            )
        )

        let secondStore = LoomTrustStore(
            storageKey: "TrustedDevices",
            suiteName: suiteName
        )
        #expect(secondStore.isTrusted(deviceID: deviceID))
        #expect(secondStore.trustedDevices.count == 1)

        secondStore.revokeTrust(for: deviceID)

        let thirdStore = LoomTrustStore(
            storageKey: "TrustedDevices",
            suiteName: suiteName
        )
        #expect(thirdStore.isTrusted(deviceID: deviceID) == false)
        #expect(thirdStore.trustedDevices.isEmpty)
    }

    private func clearSuite(named suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
