//
//  LoomCloudKitPeerManager.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Manages same-account CloudKit peer registration and refresh.
//

import CloudKit
import Foundation
import Loom
import Observation

/// Manages same-account CloudKit peer registration and refresh.
@Observable
@MainActor
public final class LoomCloudKitPeerManager {
    private struct PeerRecordPopulationAttempt {
        let attemptedOptionalPeerMetadataWrite: Bool
        let attemptedRichPeerMetadataWrite: Bool
        let attemptedBootstrapMetadataWrite: Bool
    }

    private let cloudKitManager: LoomCloudKitManager
    private let peerZoneID: CKRecordZone.ID
    private let isCloudKitAvailable: () -> Bool
    private let ensureZone: (CKRecordZone) async throws -> Void
    private let queryRecords: (CKQuery, CKRecordZone.ID) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)]
    private let fetchRecord: (CKRecord.ID) async throws -> CKRecord
    private let modifyRecords:
        ([CKRecord], [CKRecord.ID], CKModifyRecordsOperation.RecordSavePolicy) async throws -> [CKRecord.ID: Result<CKRecord, Error>]

    private var cachedPeerRecordName: String?
    private var cloudKitSchemaSupportsBootstrapMetadata = true
    private var cloudKitSchemaSupportsOptionalPeerMetadata = true
    private var cloudKitSchemaSupportsRichPeerMetadata = true
    private var cloudKitSchemaSupportsParticipantIdentityRecords = true

    public private(set) var peerRecord: CKRecord?
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    public init(cloudKitManager: LoomCloudKitManager) {
        self.cloudKitManager = cloudKitManager
        isCloudKitAvailable = { cloudKitManager.isAvailable }
        peerZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        ensureZone = { zone in
            guard let container = cloudKitManager.container else {
                throw LoomCloudKitError.containerUnavailable
            }
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
        }
        queryRecords = { query, zoneID in
            guard let container = cloudKitManager.container else {
                throw LoomCloudKitError.containerUnavailable
            }
            let (results, _) = try await container.privateCloudDatabase.records(matching: query, inZoneWith: zoneID)
            return results
        }
        fetchRecord = { recordID in
            guard let container = cloudKitManager.container else {
                throw LoomCloudKitError.containerUnavailable
            }
            return try await container.privateCloudDatabase.record(for: recordID)
        }
        modifyRecords = { records, deletions, savePolicy in
            guard let container = cloudKitManager.container else {
                throw LoomCloudKitError.containerUnavailable
            }
            let (saveResults, _) = try await container.privateCloudDatabase.modifyRecords(
                saving: records,
                deleting: deletions,
                savePolicy: savePolicy
            )
            return saveResults
        }
    }

    init(
        cloudKitManager: LoomCloudKitManager,
        isCloudKitAvailable: @escaping () -> Bool = { true },
        ensureZone: @escaping (CKRecordZone) async throws -> Void,
        queryRecords: @escaping (CKQuery, CKRecordZone.ID) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)],
        fetchRecord: @escaping (CKRecord.ID) async throws -> CKRecord,
        modifyRecords: @escaping ([CKRecord], [CKRecord.ID], CKModifyRecordsOperation.RecordSavePolicy)
            async throws -> [CKRecord.ID: Result<CKRecord, Error>]
    ) {
        self.cloudKitManager = cloudKitManager
        self.isCloudKitAvailable = isCloudKitAvailable
        peerZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        self.ensureZone = ensureZone
        self.queryRecords = queryRecords
        self.fetchRecord = fetchRecord
        self.modifyRecords = modifyRecords
    }

    public func setup() async {
        guard isCloudKitAvailable() else {
            LoomLogger.cloud("PeerManager: skipping setup because CloudKit is unavailable")
            return
        }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            try await ensureZone(CKRecordZone(zoneID: peerZoneID))
            try await refreshState()
        } catch {
            lastError = error
            LoomLogger.error(.cloud, error: error, message: "PeerManager setup failed: ")
        }
    }

    public func refresh() async {
        guard isCloudKitAvailable() else {
            peerRecord = nil
            lastError = nil
            return
        }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            try await refreshState()
        } catch {
            peerRecord = nil
            lastError = error
            LoomLogger.error(.cloud, error: error, message: "PeerManager refresh failed: ")
        }
    }

    public func registerPeer(
        deviceID: UUID,
        name: String,
        advertisement: LoomPeerAdvertisement,
        identityPublicKey: Data? = nil,
        remoteAccessEnabled: Bool = false,
        signalingSessionID: String? = nil,
        bootstrapMetadata: LoomBootstrapMetadata? = nil,
        overlayHints: [LoomCloudKitOverlayHint] = []
    ) async throws {
        guard isCloudKitAvailable() else {
            throw LoomCloudKitError.containerUnavailable
        }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        try await ensureZone(CKRecordZone(zoneID: peerZoneID))

        while true {
            let record = try await fetchOrCreatePeerRecord(deviceID: deviceID)
            let populationAttempt = populate(
                record: record,
                deviceID: deviceID,
                name: name,
                advertisement: advertisement,
                identityPublicKey: identityPublicKey,
                remoteAccessEnabled: remoteAccessEnabled,
                signalingSessionID: signalingSessionID,
                bootstrapMetadata: bootstrapMetadata,
                overlayHints: overlayHints
            )

            do {
                let storedRecord = try await persistPeerRecord(
                    record,
                    identityPublicKey: identityPublicKey
                )
                peerRecord = storedRecord
                LoomLogger.cloud("Registered peer in CloudKit: \(storedRecord.recordID.recordName)")
                return
            } catch where Self.shouldRetryRegistrationWithoutBootstrapMetadata(
                error: error,
                attemptedBootstrapMetadataWrite: populationAttempt.attemptedBootstrapMetadataWrite
            ) {
                cloudKitSchemaSupportsBootstrapMetadata = false
                LoomLogger.cloud(
                    "PeerManager: schema rejected bootstrap metadata; retrying peer registration without bootstrap metadata"
                )
            } catch where Self.shouldRetryRegistrationWithoutOptionalPeerMetadata(
                error: error,
                attemptedOptionalPeerMetadataWrite: populationAttempt.attemptedOptionalPeerMetadataWrite
            ) {
                cloudKitSchemaSupportsOptionalPeerMetadata = false
                LoomLogger.cloud(
                    "PeerManager: schema rejected optional peer metadata; retrying with base fields only"
                )
            } catch where Self.shouldRetryRegistrationWithMinimalRecordFields(
                error: error,
                attemptedRichPeerMetadataWrite: populationAttempt.attemptedRichPeerMetadataWrite
            ) {
                cloudKitSchemaSupportsRichPeerMetadata = false
                LoomLogger.cloud(
                    "PeerManager: schema rejected rich peer metadata; retrying with minimal legacy fields"
                )
            } catch {
                lastError = error
                throw error
            }
        }
    }

    public func updateLastSeen() async {
        let cachedRecord: CKRecord?
        do {
            cachedRecord = try await fetchCachedPeerRecord()
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to load cached peer record for lastSeen update: ")
            return
        }
        guard let record = cachedRecord else { return }

        record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] = Date()

        do {
            let saveResults = try await modifyRecords([record], [], .changedKeys)
            peerRecord = try saveResults[record.recordID]?.get() ?? record
        } catch {
            if Self.isUnknownItemCloudKitError(error) {
                cachedPeerRecordName = nil
                peerRecord = nil
                LoomLogger.cloud("PeerManager: cached peer record was deleted; clearing registration cache")
                return
            }
            LoomLogger.error(.cloud, error: error, message: "Failed to update peer lastSeen: ")
        }
    }

    public func cleanupStaleOwnPeers(
        currentDeviceID: UUID,
        currentPeerName: String,
        currentIdentityKeyID: String? = nil
    ) async throws -> Int {
        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(value: true)
        )

        let results: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            results = try await queryRecords(query, peerZoneID)
        } catch where Self.shouldIgnoreStaleOwnPeerCleanupFailure(error) {
            LoomLogger.cloud(
                "PeerManager: skipping stale own-peer cleanup because the peer record zone is not yet available"
            )
            return 0
        }

        let normalizedCurrentName = normalizePeerName(currentPeerName)
        let staleRecordIDs: [CKRecord.ID] = results.compactMap { _, result in
            guard case let .success(record) = result,
                  let recordDeviceID = parseRecordDeviceID(record),
                  recordDeviceID != currentDeviceID else {
                return nil
            }

            if let currentIdentityKeyID {
                let advertisementBlob = record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] as? Data
                let advertisement = advertisementBlob.flatMap {
                    try? JSONDecoder().decode(LoomPeerAdvertisement.self, from: $0)
                }
                guard advertisement?.identityKeyID == currentIdentityKeyID else {
                    return nil
                }
            }

            let recordName = (record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] as? String) ?? ""
            guard normalizePeerName(recordName) == normalizedCurrentName else {
                return nil
            }
            return record.recordID
        }

        guard !staleRecordIDs.isEmpty else { return 0 }
        _ = try await modifyRecords([], staleRecordIDs, .changedKeys)
        return staleRecordIDs.count
    }

    private func refreshState() async throws {
        peerRecord = try await fetchRegisteredPeerRecord()
    }

    private func fetchRegisteredPeerRecord() async throws -> CKRecord? {
        if let peerRecord {
            return peerRecord
        }
        if let cachedRecord = try await fetchCachedPeerRecord() {
            return cachedRecord
        }

        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(value: true)
        )
        let results = try await queryRecords(query, peerZoneID)

        for (_, result) in results {
            guard case let .success(record) = result else { continue }
            cachedPeerRecordName = record.recordID.recordName
            peerRecord = record
            return record
        }

        return nil
    }

    private func fetchOrCreatePeerRecord(deviceID: UUID) async throws -> CKRecord {
        if let peerRecord {
            return peerRecord
        }
        if let cachedRecord = try await fetchCachedPeerRecord() {
            return cachedRecord
        }

        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(
                format: "%K == %@",
                LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue,
                deviceID.uuidString
            )
        )

        do {
            let results = try await queryRecords(query, peerZoneID)
            for (_, result) in results {
                guard case let .success(record) = result else { continue }
                cachedPeerRecordName = record.recordID.recordName
                peerRecord = record
                return record
            }
        } catch where Self.shouldIgnoreExistingPeerRecordQueryFailure(error) {
            LoomLogger.cloud("PeerManager: existing peer lookup missed in CloudKit; creating a replacement record")
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to query existing peer record: ")
        }

        let recordID = CKRecord.ID(recordName: deviceID.uuidString, zoneID: peerZoneID)
        let record = CKRecord(recordType: cloudKitManager.configuration.peerRecordType, recordID: recordID)
        record[LoomCloudKitPeerInfo.RecordKey.createdAt.rawValue] = Date()
        cachedPeerRecordName = recordID.recordName
        peerRecord = record
        return record
    }

    private func fetchCachedPeerRecord() async throws -> CKRecord? {
        guard let cachedPeerRecordName else { return nil }

        let recordID = CKRecord.ID(recordName: cachedPeerRecordName, zoneID: peerZoneID)
        do {
            let record = try await fetchRecord(recordID)
            peerRecord = record
            return record
        } catch {
            if Self.isMissingPeerRecordZoneCloudKitError(error) {
                self.cachedPeerRecordName = nil
                peerRecord = nil
                return nil
            }
            throw error
        }
    }

    @discardableResult
    private func populate(
        record: CKRecord,
        deviceID: UUID,
        name: String,
        advertisement: LoomPeerAdvertisement,
        identityPublicKey: Data?,
        remoteAccessEnabled: Bool,
        signalingSessionID: String?,
        bootstrapMetadata: LoomBootstrapMetadata?,
        overlayHints: [LoomCloudKitOverlayHint]
    ) -> PeerRecordPopulationAttempt {
        record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] = deviceID.uuidString
        record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] = name

        let attemptedRichPeerMetadataWrite = cloudKitSchemaSupportsRichPeerMetadata
        if attemptedRichPeerMetadataWrite {
            record[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] = (advertisement.deviceType ?? .unknown).rawValue
            record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] = try? JSONEncoder().encode(advertisement)
        } else {
            record[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] = nil
        }

        let attemptedOptionalPeerMetadataWrite = cloudKitSchemaSupportsOptionalPeerMetadata
        if attemptedOptionalPeerMetadataWrite {
            record[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] = identityPublicKey
            record[LoomCloudKitPeerInfo.RecordKey.remoteAccessEnabled.rawValue] = remoteAccessEnabled ? 1 : 0
            record[LoomCloudKitPeerInfo.RecordKey.signalingSessionID.rawValue] = signalingSessionID
            record[LoomCloudKitPeerInfo.RecordKey.overlayHintsBlob.rawValue] = try? JSONEncoder().encode(overlayHints)
        } else {
            record[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.remoteAccessEnabled.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.signalingSessionID.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.overlayHintsBlob.rawValue] = nil
        }

        let attemptedBootstrapMetadataWrite = cloudKitSchemaSupportsBootstrapMetadata && bootstrapMetadata != nil
        if cloudKitSchemaSupportsBootstrapMetadata {
            if let bootstrapMetadata {
                record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] = try? JSONEncoder().encode(bootstrapMetadata)
            } else {
                record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] = nil
            }
        } else {
            record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] = nil
        }

        record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] = Date()

        return PeerRecordPopulationAttempt(
            attemptedOptionalPeerMetadataWrite: attemptedOptionalPeerMetadataWrite,
            attemptedRichPeerMetadataWrite: attemptedRichPeerMetadataWrite,
            attemptedBootstrapMetadataWrite: attemptedBootstrapMetadataWrite
        )
    }

    private func persistPeerRecord(
        _ record: CKRecord,
        identityPublicKey: Data?
    ) async throws -> CKRecord {
        let saveResults = try await modifyRecords([record], [], .changedKeys)
        let storedRecord = try saveResults[record.recordID]?.get() ?? record
        cachedPeerRecordName = storedRecord.recordID.recordName
        peerRecord = storedRecord

        if cloudKitSchemaSupportsParticipantIdentityRecords,
           let identityPublicKey {
            do {
                try await upsertParticipantIdentityRecord(publicKey: identityPublicKey)
            } catch where Self.shouldIgnoreParticipantIdentityRecordFailure(error) {
                cloudKitSchemaSupportsParticipantIdentityRecords = false
                LoomLogger.cloud(
                    "PeerManager: schema rejected participant identity records; continuing without participant identity metadata"
                )
            }
        }

        return storedRecord
    }

    private func upsertParticipantIdentityRecord(publicKey: Data) async throws {
        let keyID = LoomIdentityManager.keyID(for: publicKey)
        let recordID = CKRecord.ID(
            recordName: "identity-\(keyID)",
            zoneID: peerZoneID
        )
        let record = CKRecord(
            recordType: cloudKitManager.configuration.participantIdentityRecordType,
            recordID: recordID
        )
        record["keyID"] = keyID
        record["publicKey"] = publicKey
        record["lastSeen"] = Date()

        _ = try await modifyRecords([record], [], .changedKeys)
    }

    private func normalizePeerName(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseRecordDeviceID(_ record: CKRecord) -> UUID? {
        if let rawDeviceID = record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] as? String,
           let deviceID = UUID(uuidString: rawDeviceID) {
            return deviceID
        }
        return UUID(uuidString: record.recordID.recordName)
    }
}

public enum LoomCloudKitError: LocalizedError, Sendable {
    case recordNotSaved
    case containerUnavailable

    public var errorDescription: String? {
        switch self {
        case .recordNotSaved:
            "Failed to save record to CloudKit"
        case .containerUnavailable:
            "CloudKit is not available"
        }
    }
}
