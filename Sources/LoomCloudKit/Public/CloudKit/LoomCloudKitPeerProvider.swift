//
//  LoomCloudKitPeerProvider.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Fetches peer information from CloudKit.
//

import CloudKit
import Foundation
import Loom
import Observation

/// Fetches peer information from CloudKit for display in app-owned UIs.
@Observable
@MainActor
public final class LoomCloudKitPeerProvider {
    public private(set) var ownPeers: [LoomCloudKitPeerInfo] = []
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    private let cloudKitManager: LoomCloudKitManager
    private let peerZoneID: CKRecordZone.ID
    private let isCloudKitAvailable: () -> Bool
    private let ensureZone: (CKRecordZone) async throws -> Void
    private let queryRecords: (CKQuery, CKRecordZone.ID) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)]
    private let modifyRecords: ([CKRecord], [CKRecord.ID]) async throws -> Void
    private let peerRecordParser = PeerRecordSnapshotParser()
    private var hasEnsuredPeerZone = false

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
        modifyRecords = { records, deletions in
            guard let container = cloudKitManager.container else {
                throw LoomCloudKitError.containerUnavailable
            }
            _ = try await container.privateCloudDatabase.modifyRecords(saving: records, deleting: deletions)
        }
    }

    init(
        cloudKitManager: LoomCloudKitManager,
        isCloudKitAvailable: @escaping () -> Bool,
        ensureZone: @escaping (CKRecordZone) async throws -> Void,
        queryRecords: @escaping (CKQuery, CKRecordZone.ID) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)],
        modifyRecords: @escaping ([CKRecord], [CKRecord.ID]) async throws -> Void
    ) {
        self.cloudKitManager = cloudKitManager
        self.isCloudKitAvailable = isCloudKitAvailable
        peerZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        self.ensureZone = ensureZone
        self.queryRecords = queryRecords
        self.modifyRecords = modifyRecords
    }

    public func fetchPeers() async {
        guard isCloudKitAvailable() else {
            LoomLogger.cloud("CloudKit unavailable, skipping peer fetch")
            return
        }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        await refreshOwnPeers()
    }

    public func refreshOwnPeers() async {
        guard isCloudKitAvailable() else {
            ownPeers = []
            lastError = nil
            return
        }

        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let peers = try await fetchOwnPeers(query: query)
            ownPeers = peers
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to fetch own peers: ")
            lastError = error
        }
    }

    public func removeOwnPeer(deviceID: UUID) async throws {
        try await ensurePeerZoneExistsIfNeeded()

        let recordIDs = try await queryPeerRecordIDs(
            zoneID: peerZoneID,
            deviceID: deviceID
        )

        if recordIDs.isEmpty {
            ownPeers.removeAll { $0.deviceID == deviceID }
            return
        }

        try await modifyRecords([], recordIDs)
        ownPeers.removeAll { $0.deviceID == deviceID }
        LoomLogger.cloud("Removed own CloudKit peer record(s) for \(deviceID)")
    }

    public func removePeer(_ peer: LoomCloudKitPeerInfo) async throws {
        try await removeOwnPeer(deviceID: peer.deviceID)
    }

    private func makeSnapshots(
        from results: [(CKRecord.ID, Result<CKRecord, any Error>)]
    ) -> [PeerRecordSnapshot] {
        var snapshots: [PeerRecordSnapshot] = []
        for (_, result) in results {
            guard case let .success(record) = result else { continue }
            snapshots.append(
                PeerRecordSnapshot(
                    recordID: record.recordID.recordName,
                    deviceIDString: record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] as? String,
                    name: record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] as? String,
                    deviceTypeRawValue: record[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] as? String,
                    advertisementBlob: record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] as? Data,
                    identityPublicKey: record[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] as? Data,
                    remoteAccessEnabled: (record[LoomCloudKitPeerInfo.RecordKey.remoteAccessEnabled.rawValue] as? Int64).map { $0 != 0 },
                    signalingSessionID: record[LoomCloudKitPeerInfo.RecordKey.signalingSessionID.rawValue] as? String,
                    bootstrapMetadataBlob: record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] as? Data,
                    overlayHintsBlob: record[LoomCloudKitPeerInfo.RecordKey.overlayHintsBlob.rawValue] as? Data,
                    lastSeen: record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] as? Date
                )
            )
        }
        return snapshots
    }

    private func queryPeerRecordIDs(
        zoneID: CKRecordZone.ID,
        deviceID: UUID
    ) async throws -> [CKRecord.ID] {
        let query = CKQuery(
            recordType: cloudKitManager.configuration.peerRecordType,
            predicate: NSPredicate(
                format: "%K == %@",
                LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue,
                deviceID.uuidString
            )
        )
        let results = try await queryRecords(query, zoneID)
        return results.compactMap { _, result in
            try? result.get().recordID
        }
    }

    private func fetchOwnPeers(query: CKQuery) async throws -> [LoomCloudKitPeerInfo] {
        do {
            try await ensurePeerZoneExistsIfNeeded()
            let results = try await queryRecords(query, peerZoneID)
            let snapshots = makeSnapshots(from: results)
            let parsedPeers = await peerRecordParser.parse(snapshots)
            let peers = parsedPeers.sorted { $0.name < $1.name }
            lastError = nil
            LoomLogger.cloud("Fetched \(peers.count) own peers from CloudKit")
            return peers
        } catch where LoomCloudKitPeerManager.isMissingPeerZoneCloudKitError(error) {
            try await ensurePeerZoneExistsIfNeeded(force: true)
            lastError = nil
            LoomLogger.cloud("PeerProvider: recreated missing peer record zone")
            return []
        }
    }

    private func ensurePeerZoneExistsIfNeeded(force: Bool = false) async throws {
        guard force || !hasEnsuredPeerZone else { return }
        try await ensureZone(CKRecordZone(zoneID: peerZoneID))
        hasEnsuredPeerZone = true
    }
}

private struct PeerRecordSnapshot: Sendable {
    let recordID: String
    let deviceIDString: String?
    let name: String?
    let deviceTypeRawValue: String?
    let advertisementBlob: Data?
    let identityPublicKey: Data?
    let remoteAccessEnabled: Bool?
    let signalingSessionID: String?
    let bootstrapMetadataBlob: Data?
    let overlayHintsBlob: Data?
    let lastSeen: Date?
}

private actor PeerRecordSnapshotParser {
    func parse(_ snapshots: [PeerRecordSnapshot]) -> [LoomCloudKitPeerInfo] {
        snapshots.flatMap(parsePeerRecord)
    }

    private func parsePeerRecord(_ snapshot: PeerRecordSnapshot) -> [LoomCloudKitPeerInfo] {
        guard let rawDeviceID = snapshot.deviceIDString,
              let deviceID = UUID(uuidString: rawDeviceID) else {
            LoomLogger.cloud("Skipping peer record with invalid deviceID: \(snapshot.recordID)")
            return []
        }

        let deviceType = snapshot.deviceTypeRawValue.flatMap(DeviceType.init(rawValue:)) ?? .unknown
        let advertisement = snapshot.advertisementBlob.flatMap {
            try? JSONDecoder().decode(LoomPeerAdvertisement.self, from: $0)
        } ?? LoomPeerAdvertisement(
            deviceID: deviceID,
            deviceType: deviceType
        )
        let bootstrapMetadata = snapshot.bootstrapMetadataBlob.flatMap {
            try? JSONDecoder().decode(LoomBootstrapMetadata.self, from: $0)
        }
        let overlayHints = snapshot.overlayHintsBlob.flatMap {
            try? JSONDecoder().decode([LoomCloudKitOverlayHint].self, from: $0)
        } ?? []

        let projections = LoomHostCatalogCodec.projections(
            peerName: snapshot.name ?? "Unknown Peer",
            advertisement: advertisement
        )
        return projections.map { projection in
            LoomCloudKitPeerInfo(
                id: projection.peerID,
                name: projection.displayName,
                deviceType: deviceType,
                advertisement: projection.advertisement,
                lastSeen: snapshot.lastSeen ?? Date.distantPast,
                recordID: snapshot.recordID,
                identityPublicKey: snapshot.identityPublicKey,
                remoteAccessEnabled: snapshot.remoteAccessEnabled ?? false,
                signalingSessionID: snapshot.signalingSessionID,
                bootstrapMetadata: bootstrapMetadata,
                overlayHints: overlayHints
            )
        }
    }
}
