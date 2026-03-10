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
    private let cloudKitManager: LoomCloudKitManager
    private let peerZoneID: CKRecordZone.ID

    public private(set) var activeShare: CKShare?
    public private(set) var peerRecord: CKRecord?
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    public init(cloudKitManager: LoomCloudKitManager) {
        self.cloudKitManager = cloudKitManager
        peerZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    public func setup() async {
        guard cloudKitManager.isAvailable else {
            LoomLogger.cloud("ShareManager: skipping setup because CloudKit is unavailable")
            return
        }
        guard let container = cloudKitManager.container else {
            LoomLogger.cloud("ShareManager: skipping setup because container is nil")
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let zone = CKRecordZone(zoneID: peerZoneID)
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
            await fetchPeerRecord()
            if let peerRecord {
                await fetchShare(for: peerRecord)
            }
        } catch {
            lastError = error
            LoomLogger.error(.cloud, error: error, message: "ShareManager setup failed: ")
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
        guard cloudKitManager.isAvailable, let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        isLoading = true
        defer { isLoading = false }

        let zone = CKRecordZone(zoneID: peerZoneID)
        _ = try? await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])

        let record = try await fetchOrCreatePeerRecord(
            deviceID: deviceID,
            database: container.privateCloudDatabase
        )
        record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] = deviceID.uuidString
        record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] = name
        record[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] = (advertisement.deviceType ?? .unknown).rawValue
        record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] = try JSONEncoder().encode(advertisement)
        record[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] = identityPublicKey
        record[LoomCloudKitPeerInfo.RecordKey.remoteAccessEnabled.rawValue] = remoteAccessEnabled ? 1 : 0
        record[LoomCloudKitPeerInfo.RecordKey.relaySessionID.rawValue] = relaySessionID
        record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] = try? JSONEncoder().encode(bootstrapMetadata)
        record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] = Date()

        let (saveResults, _) = try await container.privateCloudDatabase.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys
        )

        guard let savedRecord = try saveResults[record.recordID]?.get() else {
            throw LoomCloudKitError.recordNotSaved
        }

        peerRecord = savedRecord
        LoomLogger.cloud("Registered peer in CloudKit: \(name)")
    }

    public func updateLastSeen() async {
        guard let record = peerRecord,
              let container = cloudKitManager.container else {
            return
        }

        record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] = Date()

        do {
            _ = try await container.privateCloudDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys
            )
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to update peer lastSeen: ")
        }
    }

    public func cleanupStaleOwnPeers(
        currentDeviceID: UUID,
        currentPeerName: String
    ) async throws -> Int {
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(value: true)
        )
        let (results, _) = try await container.privateCloudDatabase.records(
            matching: query,
            inZoneWith: peerZoneID
        )

        let normalizedCurrentName = normalizePeerName(currentPeerName)
        let staleRecordIDs: [CKRecord.ID] = results.compactMap { _, result in
            guard case let .success(record) = result,
                  let recordDeviceID = parseRecordDeviceID(record),
                  recordDeviceID != currentDeviceID else {
                return nil
            }

            let recordName = (record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] as? String) ?? ""
            guard normalizePeerName(recordName) == normalizedCurrentName else {
                return nil
            }
            return record.recordID
        }

        guard !staleRecordIDs.isEmpty else { return 0 }
        _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: staleRecordIDs)
        return staleRecordIDs.count
    }

    public func createShare() async throws -> CKShare {
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        let record = if let peerRecord {
            peerRecord
        } else {
            try await createPeerRecord()
        }

        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = cloudKitManager.configuration.shareTitle
        share.publicPermission = .none

        _ = try await container.privateCloudDatabase.modifyRecords(saving: [record, share], deleting: [])
        activeShare = share
        return share
    }

    public func revokeShare() async throws {
        guard let share = activeShare else { return }
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: [share.recordID])
        activeShare = nil
    }

    public func removeParticipant(_ participant: CKShare.Participant) async throws {
        guard let share = activeShare else { return }
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        share.removeParticipant(participant)
        _ = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
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

    private func fetchPeerRecord() async {
        guard let container = cloudKitManager.container else { return }

        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let (results, _) = try await container.privateCloudDatabase.records(
                matching: query,
                inZoneWith: peerZoneID
            )
            for (_, result) in results {
                if case let .success(record) = result {
                    peerRecord = record
                    return
                }
            }
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to fetch peer record: ")
        }
    }

    private func createPeerRecord() async throws -> CKRecord {
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        #if os(macOS)
        let peerName = Host.current().localizedName ?? "Mac"
        #else
        let peerName = "My Device"
        #endif

        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: peerZoneID)
        let record = CKRecord(recordType: cloudKitManager.configuration.peerRecordType, recordID: recordID)
        record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] = peerName
        record[LoomCloudKitPeerInfo.RecordKey.createdAt.rawValue] = Date()

        let (saveResults, _) = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [])
        guard let savedRecord = try saveResults[recordID]?.get() else {
            throw LoomCloudKitError.recordNotSaved
        }

        peerRecord = savedRecord
        return savedRecord
    }

    private func fetchOrCreatePeerRecord(
        deviceID: UUID,
        database: CKDatabase
    ) async throws -> CKRecord {
        if let peerRecord {
            return peerRecord
        }

        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(format: "%K == %@", LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue, deviceID.uuidString)
        )

        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: peerZoneID)
            for (_, result) in results {
                if case let .success(record) = result {
                    peerRecord = record
                    return record
                }
            }
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to query existing peer record: ")
        }

        let recordID = CKRecord.ID(recordName: deviceID.uuidString, zoneID: peerZoneID)
        let record = CKRecord(recordType: cloudKitManager.configuration.peerRecordType, recordID: recordID)
        record[LoomCloudKitPeerInfo.RecordKey.createdAt.rawValue] = Date()
        peerRecord = record
        return record
    }

    private func fetchShare(for record: CKRecord) async {
        guard let shareReference = record.share else { return }
        guard let container = cloudKitManager.container else { return }

        do {
            activeShare = try await container.privateCloudDatabase.record(for: shareReference.recordID) as? CKShare
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to fetch share: ")
        }
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
