//
//  LoomCloudKitPeerProviderTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/5/26.
//

import CloudKit
@testable import LoomCloudKit
import Testing

@Suite("Loom CloudKit Peer Provider")
struct LoomCloudKitPeerProviderTests {
    @Test("CloudKit peer provider recreates a missing peer zone and returns an empty list")
    @MainActor
    func peerProviderRecreatesMissingPeerZone() async throws {
        let configuration = LoomCloudKitConfiguration(containerIdentifier: "iCloud.com.example.test")
        let manager = LoomCloudKitManager(configuration: configuration)
        let tracker = PeerProviderTracker()
        let provider = LoomCloudKitPeerProvider(
            cloudKitManager: manager,
            isCloudKitAvailable: { true },
            ensureZone: { _ in
                await tracker.ensureZone()
            },
            queryRecords: { _, _ in
                try await tracker.queryRecords()
            },
            modifyRecords: { _, _ in }
        )

        await provider.fetchPeers()

        #expect(provider.ownPeers.isEmpty)
        #expect(provider.lastError == nil)
        #expect(await tracker.ensureZoneCallCount() == 2)
        #expect(await tracker.queryCallCount() == 1)
    }
}

private actor PeerProviderTracker {
    private var ensureZoneCalls = 0
    private var queryCalls = 0

    func ensureZone() {
        ensureZoneCalls += 1
    }

    func queryRecords() throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        queryCalls += 1
        throw CKError(.zoneNotFound)
    }

    func ensureZoneCallCount() -> Int {
        ensureZoneCalls
    }

    func queryCallCount() -> Int {
        queryCalls
    }
}
