//
//  LoomCloudKitShareManager.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Manages CloudKit sharing for peer access.
//

import CloudKit
import Foundation
import Loom
import Observation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Manages CloudKit sharing for allowing peers to discover and access each other.
@Observable
@MainActor
public final class LoomCloudKitShareManager {
    public typealias ShareThumbnailDataProvider = @Sendable (CKRecord) -> Data?

    private struct PeerRecordPopulationAttempt {
        let attemptedOptionalPeerMetadataWrite: Bool
        let attemptedRichPeerMetadataWrite: Bool
        let attemptedBootstrapMetadataWrite: Bool
    }

    private let cloudKitManager: LoomCloudKitManager
    private let peerZoneID: CKRecordZone.ID
    private let isCloudKitAvailable: () -> Bool
    private let shareThumbnailDataProvider: ShareThumbnailDataProvider
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

    public private(set) var activeShare: CKShare?
    public private(set) var peerRecord: CKRecord?
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    public init(
        cloudKitManager: LoomCloudKitManager,
        shareThumbnailDataProvider: @escaping ShareThumbnailDataProvider = { _ in nil }
    ) {
        self.cloudKitManager = cloudKitManager
        self.shareThumbnailDataProvider = shareThumbnailDataProvider
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
        shareThumbnailDataProvider: @escaping ShareThumbnailDataProvider = { _ in nil },
        isCloudKitAvailable: @escaping () -> Bool = { true },
        ensureZone: @escaping (CKRecordZone) async throws -> Void,
        queryRecords: @escaping (CKQuery, CKRecordZone.ID) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)],
        fetchRecord: @escaping (CKRecord.ID) async throws -> CKRecord,
        modifyRecords: @escaping ([CKRecord], [CKRecord.ID], CKModifyRecordsOperation.RecordSavePolicy)
            async throws -> [CKRecord.ID: Result<CKRecord, Error>]
    ) {
        self.cloudKitManager = cloudKitManager
        self.shareThumbnailDataProvider = shareThumbnailDataProvider
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
            LoomLogger.cloud("ShareManager: skipping setup because CloudKit is unavailable")
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
            LoomLogger.error(.cloud, error: error, message: "ShareManager setup failed: ")
        }
    }

    public func refresh() async {
        guard isCloudKitAvailable() else {
            peerRecord = nil
            activeShare = nil
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
            activeShare = nil
            lastError = error
            LoomLogger.error(.cloud, error: error, message: "ShareManager refresh failed: ")
        }
    }

    public func registerPeer(
        deviceID: UUID,
        name: String,
        advertisement: LoomPeerAdvertisement,
        identityPublicKey: Data? = nil,
        remoteAccessEnabled: Bool = false,
        relaySessionID: String? = nil,
        bootstrapMetadata: LoomBootstrapMetadata? = nil
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
                relaySessionID: relaySessionID,
                bootstrapMetadata: bootstrapMetadata
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
                    "ShareManager: schema rejected bootstrap metadata; retrying peer registration without bootstrap metadata"
                )
            } catch where Self.shouldRetryRegistrationWithoutOptionalPeerMetadata(
                error: error,
                attemptedOptionalPeerMetadataWrite: populationAttempt.attemptedOptionalPeerMetadataWrite
            ) {
                cloudKitSchemaSupportsOptionalPeerMetadata = false
                LoomLogger.cloud(
                    "ShareManager: schema rejected optional peer metadata; retrying with base fields only"
                )
            } catch where Self.shouldRetryRegistrationWithMinimalRecordFields(
                error: error,
                attemptedRichPeerMetadataWrite: populationAttempt.attemptedRichPeerMetadataWrite
            ) {
                cloudKitSchemaSupportsRichPeerMetadata = false
                LoomLogger.cloud(
                    "ShareManager: schema rejected rich peer metadata; retrying with minimal legacy fields"
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
                activeShare = nil
                LoomLogger.cloud("ShareManager: cached peer record was deleted; clearing registration cache")
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
                "ShareManager: skipping stale own-peer cleanup because the peer record zone is not yet available"
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

    public func createShare() async throws -> CKShare {
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            let share = try await ensureShare()
            activeShare = share
            return share
        } catch {
            lastError = error
            throw error
        }
    }

    public func revokeShare() async throws {
        guard let share = activeShare else { return }
        _ = try await modifyRecords([], [share.recordID], .changedKeys)
        activeShare = nil
    }

    public func removeParticipant(_ participant: CKShare.Participant) async throws {
        guard let share = activeShare else { return }

        share.removeParticipant(participant)
        let saveResults = try await modifyRecords([share], [], .changedKeys)
        activeShare = try saveResults[share.recordID]?.get() as? CKShare ?? share
        cloudKitManager.clearShareParticipantCache()
    }

    #if os(macOS)
    public func presentSharingUI(from _: NSWindow) async throws {
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        let share = try await createShareIfNeeded()
        guard peerRecord != nil else { throw LoomCloudKitError.noPeerRecord }

        let sharingService = NSSharingService(named: .cloudSharing)
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)
        sharingService?.perform(withItems: [itemProvider])
    }
    #endif

    #if os(iOS) || os(visionOS)
    public func createSharingController() async throws -> UICloudSharingController {
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        let share = try await createShareIfNeeded()
        guard peerRecord != nil else { throw LoomCloudKitError.noPeerRecord }

        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite]
        return controller
    }
    #endif

    public func acceptShare(_ metadata: CKShare.Metadata) async throws {
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        try await container.accept(metadata)
        cloudKitManager.clearShareParticipantCache()
    }

    private func createShareIfNeeded() async throws -> CKShare {
        if let activeShare {
            return activeShare
        }
        return try await createShare()
    }

    private func refreshState() async throws {
        if let record = try await fetchRegisteredPeerRecord() {
            peerRecord = record
            activeShare = try await fetchShare(for: record)
        } else {
            peerRecord = nil
            activeShare = nil
        }
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
            LoomLogger.cloud("ShareManager: existing peer lookup missed in CloudKit; creating a replacement record")
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
            if Self.isUnknownItemCloudKitError(error) {
                self.cachedPeerRecordName = nil
                peerRecord = nil
                activeShare = nil
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
        relaySessionID: String?,
        bootstrapMetadata: LoomBootstrapMetadata?
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
            record[LoomCloudKitPeerInfo.RecordKey.relaySessionID.rawValue] = relaySessionID
        } else {
            record[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.remoteAccessEnabled.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.relaySessionID.rawValue] = nil
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
                    "ShareManager: schema rejected participant identity records; continuing without participant identity metadata"
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

    private func ensureShare() async throws -> CKShare {
        let record = if let peerRecord {
            peerRecord
        } else if let record = try await fetchRegisteredPeerRecord() {
            record
        } else {
            try await createPeerRecord()
        }

        let existingShare = if let activeShare {
            activeShare
        } else {
            try await fetchShare(for: record)
        }

        if let existingShare {
            if configureShare(existingShare, from: record) {
                let saveResults = try await modifyRecords([existingShare], [], .changedKeys)
                let savedShare = try saveResults[existingShare.recordID]?.get() as? CKShare ?? existingShare
                activeShare = savedShare
                return savedShare
            }

            activeShare = existingShare
            return existingShare
        }

        let share = CKShare(rootRecord: record)
        _ = configureShare(share, from: record)

        let saveResults = try await modifyRecords([record, share], [], .changedKeys)
        if let savedRecord = try saveResults[record.recordID]?.get() {
            peerRecord = savedRecord
            cachedPeerRecordName = savedRecord.recordID.recordName
        }
        guard let savedShare = try saveResults[share.recordID]?.get() as? CKShare else {
            throw LoomCloudKitError.shareNotFound
        }

        activeShare = savedShare
        return savedShare
    }

    private func createPeerRecord() async throws -> CKRecord {
        #if os(macOS)
        let peerName = Host.current().localizedName ?? "Mac"
        #else
        let peerName = "My Device"
        #endif

        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: peerZoneID)
        let record = CKRecord(recordType: cloudKitManager.configuration.peerRecordType, recordID: recordID)
        record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] = peerName
        record[LoomCloudKitPeerInfo.RecordKey.createdAt.rawValue] = Date()

        let saveResults = try await modifyRecords([record], [], .changedKeys)
        let savedRecord = try saveResults[recordID]?.get() ?? record
        cachedPeerRecordName = savedRecord.recordID.recordName
        peerRecord = savedRecord
        return savedRecord
    }

    private func fetchShare(for record: CKRecord) async throws -> CKShare? {
        guard let shareReference = record.share else { return nil }

        do {
            return try await fetchRecord(shareReference.recordID) as? CKShare
        } catch {
            if Self.isUnknownItemCloudKitError(error) {
                return nil
            }
            throw error
        }
    }

    @discardableResult
    private func configureShare(_ share: CKShare, from peerRecord: CKRecord) -> Bool {
        let expectedThumbnailData = shareThumbnailDataProvider(peerRecord)
        let currentTitle = share[CKShare.SystemFieldKey.title] as? String
        let currentThumbnailData = share[CKShare.SystemFieldKey.thumbnailImageData] as? Data
        let needsUpdate = currentTitle != cloudKitManager.configuration.shareTitle ||
            currentThumbnailData != expectedThumbnailData ||
            share.publicPermission != .none

        share[CKShare.SystemFieldKey.title] = cloudKitManager.configuration.shareTitle
        share[CKShare.SystemFieldKey.thumbnailImageData] = expectedThumbnailData
        share.publicPermission = .none

        return needsUpdate
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
    case noPeerRecord
    case shareNotFound
    case containerUnavailable

    public var errorDescription: String? {
        switch self {
        case .recordNotSaved:
            "Failed to save record to CloudKit"
        case .noPeerRecord:
            "No peer record available for sharing"
        case .shareNotFound:
            "Share not found"
        case .containerUnavailable:
            "CloudKit is not available"
        }
    }
}
