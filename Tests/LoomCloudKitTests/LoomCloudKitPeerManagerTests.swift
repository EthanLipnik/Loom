//
//  LoomCloudKitPeerManagerTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/11/26.
//

import CloudKit
@testable import Loom
@testable import LoomCloudKit
import Foundation
import Testing

@Suite("Loom CloudKit Peer Manager")
struct LoomCloudKitPeerManagerTests {
    @Test("Compatibility helpers classify retryable and ignorable CloudKit errors")
    func compatibilityHelpersClassifyCloudKitErrors() {
        #expect(
            LoomCloudKitPeerManager.shouldRetryRegistrationWithoutBootstrapMetadata(
                error: CKError(.invalidArguments),
                attemptedBootstrapMetadataWrite: true
            )
        )
        #expect(
            LoomCloudKitPeerManager.shouldRetryRegistrationWithoutOptionalPeerMetadata(
                error: CKError(.invalidArguments),
                attemptedOptionalPeerMetadataWrite: true
            )
        )
        #expect(
            LoomCloudKitPeerManager.shouldRetryRegistrationWithMinimalRecordFields(
                error: CKError(.invalidArguments),
                attemptedRichPeerMetadataWrite: true
            )
        )
        #expect(LoomCloudKitPeerManager.shouldIgnoreParticipantIdentityRecordFailure(CKError(.invalidArguments)))
        #expect(LoomCloudKitPeerManager.shouldIgnoreExistingPeerRecordQueryFailure(CKError(.unknownItem)))
        #expect(LoomCloudKitPeerManager.shouldIgnoreStaleOwnPeerCleanupFailure(CKError(.unknownItem)))
        #expect(LoomCloudKitPeerManager.shouldIgnoreExistingPeerRecordQueryFailure(CKError(.zoneNotFound)))
        #expect(LoomCloudKitPeerManager.shouldIgnoreStaleOwnPeerCleanupFailure(CKError(.zoneNotFound)))
    }

    @Test("Production schema rejection is classified for peer records")
    func productionSchemaRejectionIsClassified() {
        let peerError = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type LoomPeer in production schema"
            ]
        )

        #expect(
            LoomCloudKitPeerManager.isMissingProductionSchemaRecordTypeError(
                peerError,
                recordType: "LoomPeer"
            )
        )
    }

    @MainActor
    @Test("registerPeer retries through legacy schema fallbacks, publishes participant identity, and stores overlay hints")
    func registerPeerRetriesAndStoresOverlayHints() async throws {
        let configuration = LoomCloudKitConfiguration(containerIdentifier: "iCloud.com.example.test")
        let cloudKitManager = LoomCloudKitManager(configuration: configuration)
        let tracker = RegistrationTracker(configuration: configuration)
        let manager = LoomCloudKitPeerManager(
            cloudKitManager: cloudKitManager,
            ensureZone: { _ in },
            queryRecords: { query, zoneID in
                try await tracker.queryRecords(query: query, zoneID: zoneID)
            },
            fetchRecord: { recordID in
                try await tracker.fetchRecord(recordID: recordID)
            },
            modifyRecords: { records, deletions, savePolicy in
                try await tracker.modifyRecords(
                    records: records,
                    deletions: deletions,
                    savePolicy: savePolicy
                )
            }
        )

        let deviceID = UUID()
        let identityPublicKey = Data(repeating: 0xAB, count: 33)
        let overlayHints = [
            LoomCloudKitOverlayHint(host: "altair.tailnet.ts.net", probePort: 9850),
            LoomCloudKitOverlayHint(host: "10.8.0.12", probePort: 9980),
        ]
        try await manager.registerPeer(
            deviceID: deviceID,
            name: "Test Mac",
            advertisement: makeAdvertisement(deviceID: deviceID, identityKeyID: "identity-key"),
            identityPublicKey: identityPublicKey,
            remoteAccessEnabled: true,
            signalingSessionID: "relay-session",
            bootstrapMetadata: makeBootstrapMetadata(),
            overlayHints: overlayHints
        )

        let attempts = await tracker.peerSaveAttempts()
        #expect(attempts.count == 4)
        #expect(attempts[0].bootstrapMetadataBlob != nil)
        #expect(attempts[0].identityPublicKey != nil)
        #expect(attempts[0].deviceType != nil)
        #expect(attempts[0].overlayHintsBlob != nil)
        #expect(attempts[1].bootstrapMetadataBlob == nil)
        #expect(attempts[1].identityPublicKey != nil)
        #expect(attempts[1].deviceType != nil)
        #expect(attempts[1].overlayHintsBlob != nil)
        #expect(attempts[2].bootstrapMetadataBlob == nil)
        #expect(attempts[2].identityPublicKey == nil)
        #expect(attempts[2].deviceType != nil)
        #expect(attempts[2].overlayHintsBlob == nil)
        #expect(attempts[3].bootstrapMetadataBlob == nil)
        #expect(attempts[3].identityPublicKey == nil)
        #expect(attempts[3].deviceType == nil)
        #expect(attempts[3].overlayHintsBlob == nil)
        #expect(manager.peerRecord?.recordID.recordName == deviceID.uuidString)

        let encodedHints = try #require(attempts[0].overlayHintsBlob)
        let decodedHints = try JSONDecoder().decode([LoomCloudKitOverlayHint].self, from: encodedHints)
        #expect(decodedHints == overlayHints)

        let identityRecordNames = await tracker.participantIdentityRecordNames()
        #expect(identityRecordNames == ["identity-\(LoomIdentityManager.keyID(for: identityPublicKey))"])
    }

    @MainActor
    @Test("cleanupStaleOwnPeers removes only matching identity and normalized name")
    func cleanupStaleOwnPeersMatchesIdentity() async throws {
        let configuration = LoomCloudKitConfiguration(containerIdentifier: "iCloud.com.example.test")
        let cloudKitManager = LoomCloudKitManager(configuration: configuration)
        let currentDeviceID = UUID()
        let matchingIdentity = "identity-key"
        let zoneID = CKRecordZone.ID(
            zoneName: configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )

        let matchingStaleRecord = makePeerRecord(
            configuration: configuration,
            recordName: "stale-peer",
            deviceID: UUID(),
            name: "Test Mac",
            identityKeyID: matchingIdentity,
            zoneID: zoneID
        )
        let differentIdentityRecord = makePeerRecord(
            configuration: configuration,
            recordName: "different-identity",
            deviceID: UUID(),
            name: "Test Mac",
            identityKeyID: "other-identity",
            zoneID: zoneID
        )
        let differentNameRecord = makePeerRecord(
            configuration: configuration,
            recordName: "different-name",
            deviceID: UUID(),
            name: "Other Mac",
            identityKeyID: matchingIdentity,
            zoneID: zoneID
        )
        let tracker = CleanupTracker(
            results: [
                matchingStaleRecord,
                differentIdentityRecord,
                differentNameRecord,
            ]
        )
        let manager = LoomCloudKitPeerManager(
            cloudKitManager: cloudKitManager,
            ensureZone: { _ in },
            queryRecords: { query, zoneID in
                try await tracker.queryRecords(query: query, zoneID: zoneID)
            },
            fetchRecord: { recordID in
                try await tracker.fetchRecord(recordID: recordID)
            },
            modifyRecords: { records, deletions, savePolicy in
                try await tracker.modifyRecords(
                    records: records,
                    deletions: deletions,
                    savePolicy: savePolicy
                )
            }
        )

        let deletedCount = try await manager.cleanupStaleOwnPeers(
            currentDeviceID: currentDeviceID,
            currentPeerName: " test mac ",
            currentIdentityKeyID: matchingIdentity
        )

        #expect(deletedCount == 1)
        #expect(await tracker.deletedRecordNames() == [matchingStaleRecord.recordID.recordName])
    }

    @MainActor
    @Test("updateLastSeen clears stale cache so registration can recover")
    func updateLastSeenClearsCacheForRecovery() async throws {
        let configuration = LoomCloudKitConfiguration(containerIdentifier: "iCloud.com.example.test")
        let cloudKitManager = LoomCloudKitManager(configuration: configuration)
        let initialRecord = makePeerRecord(
            configuration: configuration,
            recordName: "server-generated-record",
            deviceID: UUID(),
            name: "Test Mac",
            identityKeyID: "identity-key"
        )
        let tracker = RecoveryTracker(configuration: configuration, existingRecord: initialRecord)
        let manager = LoomCloudKitPeerManager(
            cloudKitManager: cloudKitManager,
            ensureZone: { _ in },
            queryRecords: { query, zoneID in
                try await tracker.queryRecords(query: query, zoneID: zoneID)
            },
            fetchRecord: { recordID in
                try await tracker.fetchRecord(recordID: recordID)
            },
            modifyRecords: { records, deletions, savePolicy in
                try await tracker.modifyRecords(
                    records: records,
                    deletions: deletions,
                    savePolicy: savePolicy
                )
            }
        )

        try await manager.registerPeer(
            deviceID: initialRecord.deviceID(),
            name: "Test Mac",
            advertisement: makeAdvertisement(deviceID: initialRecord.deviceID(), identityKeyID: "identity-key")
        )
        await manager.updateLastSeen()

        #expect(manager.peerRecord == nil)

        try await manager.registerPeer(
            deviceID: initialRecord.deviceID(),
            name: "Test Mac",
            advertisement: makeAdvertisement(deviceID: initialRecord.deviceID(), identityKeyID: "identity-key")
        )

        #expect(manager.peerRecord?.recordID.recordName == initialRecord.deviceID().uuidString)
    }

    @MainActor
    @Test("updateLastSeen reuses the in-memory peer record instead of refetching it")
    func updateLastSeenUsesInMemoryPeerRecord() async throws {
        let configuration = LoomCloudKitConfiguration(containerIdentifier: "iCloud.com.example.test")
        let cloudKitManager = LoomCloudKitManager(configuration: configuration)
        let existingRecord = makePeerRecord(
            configuration: configuration,
            recordName: "existing-peer-record",
            deviceID: UUID(),
            name: "Test Mac",
            identityKeyID: "identity-key"
        )
        let tracker = InMemoryLastSeenTracker(configuration: configuration, existingRecord: existingRecord)
        let manager = LoomCloudKitPeerManager(
            cloudKitManager: cloudKitManager,
            ensureZone: { _ in },
            queryRecords: { query, zoneID in
                try await tracker.queryRecords(query: query, zoneID: zoneID)
            },
            fetchRecord: { recordID in
                try await tracker.fetchRecord(recordID: recordID)
            },
            modifyRecords: { records, deletions, savePolicy in
                try await tracker.modifyRecords(
                    records: records,
                    deletions: deletions,
                    savePolicy: savePolicy
                )
            }
        )

        try await manager.registerPeer(
            deviceID: existingRecord.deviceID(),
            name: "Test Mac",
            advertisement: makeAdvertisement(deviceID: existingRecord.deviceID(), identityKeyID: "identity-key")
        )
        await manager.updateLastSeen()

        #expect(await tracker.fetchCount() == 0)
    }

    @MainActor
    @Test("updateLastSeen retries transient save failures without clearing the cached registration")
    func updateLastSeenRetriesRecoverableFailure() async throws {
        let configuration = LoomCloudKitConfiguration(containerIdentifier: "iCloud.com.example.test")
        let cloudKitManager = LoomCloudKitManager(configuration: configuration)
        let initialRecord = makePeerRecord(
            configuration: configuration,
            recordName: "server-generated-record",
            deviceID: UUID(),
            name: "Test Mac",
            identityKeyID: "identity-key"
        )
        let tracker = RecoveryTracker(
            configuration: configuration,
            existingRecord: initialRecord,
            failureCode: .zoneBusy
        )
        let manager = LoomCloudKitPeerManager(
            cloudKitManager: cloudKitManager,
            ensureZone: { _ in },
            queryRecords: { query, zoneID in
                try await tracker.queryRecords(query: query, zoneID: zoneID)
            },
            fetchRecord: { recordID in
                try await tracker.fetchRecord(recordID: recordID)
            },
            modifyRecords: { records, deletions, savePolicy in
                try await tracker.modifyRecords(
                    records: records,
                    deletions: deletions,
                    savePolicy: savePolicy
                )
            }
        )

        try await manager.registerPeer(
            deviceID: initialRecord.deviceID(),
            name: "Test Mac",
            advertisement: makeAdvertisement(deviceID: initialRecord.deviceID(), identityKeyID: "identity-key")
        )
        await manager.updateLastSeen()

        #expect(manager.peerRecord?.recordID.recordName == initialRecord.recordID.recordName)
    }
}

private actor RegistrationTracker {
    struct SaveAttempt: Sendable {
        let bootstrapMetadataBlob: Data?
        let identityPublicKey: Data?
        let deviceType: String?
        let overlayHintsBlob: Data?
    }

    private let configuration: LoomCloudKitConfiguration
    private var attempts: [SaveAttempt] = []
    private var participantIdentityNames: [String] = []

    init(configuration: LoomCloudKitConfiguration) {
        self.configuration = configuration
    }

    func queryRecords(
        query _: CKQuery,
        zoneID _: CKRecordZone.ID
    ) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        []
    }

    func fetchRecord(recordID _: CKRecord.ID) async throws -> CKRecord {
        throw LoomCloudKitError.recordNotSaved
    }

    func modifyRecords(
        records: [CKRecord],
        deletions _: [CKRecord.ID],
        savePolicy _: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        if let identityRecord = records.first(where: { $0.recordType == configuration.participantIdentityRecordType }) {
            participantIdentityNames.append(identityRecord.recordID.recordName)
            return [identityRecord.recordID: .success(identityRecord)]
        }

        guard let peerRecord = records.first else {
            return [:]
        }

        attempts.append(
            SaveAttempt(
                bootstrapMetadataBlob: peerRecord[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] as? Data,
                identityPublicKey: peerRecord[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] as? Data,
                deviceType: peerRecord[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] as? String,
                overlayHintsBlob: peerRecord[LoomCloudKitPeerInfo.RecordKey.overlayHintsBlob.rawValue] as? Data
            )
        )

        if attempts.count < 4 {
            throw CKError(.invalidArguments)
        }

        return [peerRecord.recordID: .success(peerRecord)]
    }

    func peerSaveAttempts() -> [SaveAttempt] {
        attempts
    }

    func participantIdentityRecordNames() -> [String] {
        participantIdentityNames
    }
}

private actor CleanupTracker {
    private let results: [CKRecord]
    private var deletedNames: [String] = []

    init(results: [CKRecord]) {
        self.results = results
    }

    func queryRecords(
        query _: CKQuery,
        zoneID _: CKRecordZone.ID
    ) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        results.map { ($0.recordID, .success($0)) }
    }

    func fetchRecord(recordID _: CKRecord.ID) async throws -> CKRecord {
        throw LoomCloudKitError.recordNotSaved
    }

    func modifyRecords(
        records _: [CKRecord],
        deletions: [CKRecord.ID],
        savePolicy _: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        deletedNames = deletions.map(\.recordName)
        return [:]
    }

    func deletedRecordNames() -> [String] {
        deletedNames
    }
}

private actor RecoveryTracker {
    private let configuration: LoomCloudKitConfiguration
    private let existingRecord: CKRecord
    private let failureCode: CKError.Code
    private var didRegisterExistingRecord = false
    private var shouldReturnExistingRecord = true
    private var shouldFailNextLastSeenSave = true

    init(
        configuration: LoomCloudKitConfiguration,
        existingRecord: CKRecord,
        failureCode: CKError.Code = .unknownItem
    ) {
        self.configuration = configuration
        self.existingRecord = existingRecord
        self.failureCode = failureCode
    }

    func queryRecords(
        query _: CKQuery,
        zoneID _: CKRecordZone.ID
    ) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        guard shouldReturnExistingRecord else { return [] }
        return [(existingRecord.recordID, .success(existingRecord))]
    }

    func fetchRecord(recordID: CKRecord.ID) async throws -> CKRecord {
        if recordID.recordName == existingRecord.recordID.recordName {
            return existingRecord
        }
        throw CKError(.unknownItem)
    }

    func modifyRecords(
        records: [CKRecord],
        deletions _: [CKRecord.ID],
        savePolicy _: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        guard let record = records.first(where: { $0.recordType == configuration.peerRecordType }) else {
            return [:]
        }

        if record.recordID.recordName == existingRecord.recordID.recordName && !didRegisterExistingRecord {
            didRegisterExistingRecord = true
            return [record.recordID: .success(record)]
        }

        if record.recordID.recordName == existingRecord.recordID.recordName && shouldFailNextLastSeenSave {
            shouldFailNextLastSeenSave = false
            shouldReturnExistingRecord = false
            throw CKError(failureCode)
        }

        return [record.recordID: .success(record)]
    }
}

private actor InMemoryLastSeenTracker {
    private let configuration: LoomCloudKitConfiguration
    private let existingRecord: CKRecord
    private var fetchInvocationCount = 0

    init(configuration: LoomCloudKitConfiguration, existingRecord: CKRecord) {
        self.configuration = configuration
        self.existingRecord = existingRecord
    }

    func queryRecords(
        query _: CKQuery,
        zoneID _: CKRecordZone.ID
    ) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        [(existingRecord.recordID, .success(existingRecord))]
    }

    func fetchRecord(recordID: CKRecord.ID) async throws -> CKRecord {
        fetchInvocationCount += 1
        if recordID.recordName == existingRecord.recordID.recordName {
            return existingRecord
        }
        throw CKError(.unknownItem)
    }

    func modifyRecords(
        records: [CKRecord],
        deletions _: [CKRecord.ID],
        savePolicy _: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        guard let record = records.first(where: { $0.recordType == configuration.peerRecordType }) else {
            return [:]
        }
        return [record.recordID: .success(record)]
    }

    func fetchCount() -> Int {
        fetchInvocationCount
    }
}

private func makeBootstrapMetadata() -> LoomBootstrapMetadata {
    LoomBootstrapMetadata(
        enabled: true,
        supportsPreloginDaemon: true,
        endpoints: [LoomBootstrapEndpoint(host: "203.0.113.10", port: 22, source: .user)],
        sshPort: 22,
        controlPort: 9851,
        wakeOnLAN: nil
    )
}

private func makeAdvertisement(
    deviceID: UUID,
    identityKeyID: String?
) -> LoomPeerAdvertisement {
    LoomPeerAdvertisement(
        protocolVersion: Int(Loom.protocolVersion),
        deviceID: deviceID,
        identityKeyID: identityKeyID,
        deviceType: .mac
    )
}

private func makePeerRecord(
    configuration: LoomCloudKitConfiguration,
    recordName: String,
    deviceID: UUID,
    name: String,
    identityKeyID: String?,
    zoneID: CKRecordZone.ID? = nil
) -> CKRecord {
    let zoneID = zoneID ?? CKRecordZone.ID(
        zoneName: configuration.peerZoneName,
        ownerName: CKCurrentUserDefaultName
    )
    let record = CKRecord(
        recordType: configuration.peerRecordType,
        recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID)
    )
    record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] = deviceID.uuidString
    record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] = name
    record[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] = DeviceType.mac.rawValue
    record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] = try? JSONEncoder().encode(
        makeAdvertisement(deviceID: deviceID, identityKeyID: identityKeyID)
    )
    return record
}

private extension CKRecord {
    func deviceID() -> UUID {
        let rawDeviceID = self[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] as? String ?? recordID.recordName
        return UUID(uuidString: rawDeviceID) ?? UUID()
    }
}
