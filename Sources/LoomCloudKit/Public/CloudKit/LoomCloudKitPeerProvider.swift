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
    public private(set) var sharedPeers: [LoomCloudKitPeerInfo] = []
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    private let cloudKitManager: LoomCloudKitManager
    private let peerZoneID: CKRecordZone.ID
    private let peerRecordParser = PeerRecordSnapshotParser()

    public init(cloudKitManager: LoomCloudKitManager) {
        self.cloudKitManager = cloudKitManager
        peerZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    public func fetchPeers() async {
        guard cloudKitManager.isAvailable else {
            LoomLogger.cloud("CloudKit unavailable, skipping peer fetch")
            return
        }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        async let ownTask: () = refreshOwnPeers()
        async let sharedTask: () = refreshSharedPeers()

        await ownTask
        await sharedTask
    }

    public func refreshOwnPeers() async {
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

            let snapshots = makeSnapshots(
                from: results,
                isShared: false,
                ownerUserID: nil
            )
            let peers = await peerRecordParser.parse(snapshots)
            ownPeers = peers.sorted { $0.name < $1.name }
            LoomLogger.cloud("Fetched \(peers.count) own peers from CloudKit")
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to fetch own peers: ")
            lastError = error
        }
    }

    public func refreshSharedPeers() async {
        guard let container = cloudKitManager.container else { return }

        let sharedDatabase = container.sharedCloudDatabase

        do {
            let zones = try await sharedDatabase.allRecordZones()
            var snapshots: [PeerRecordSnapshot] = []
            var processedCount = 0

            for zone in zones {
                let query = CKQuery(
                    recordType: cloudKitManager.configuration.peerRecordType,
                    predicate: NSPredicate(value: true)
                )

                do {
                    let (results, _) = try await sharedDatabase.records(
                        matching: query,
                        inZoneWith: zone.zoneID
                    )
                    snapshots.append(
                        contentsOf: makeSnapshots(
                            from: results,
                            isShared: true,
                            ownerUserID: zone.zoneID.ownerName
                        )
                    )
                    processedCount += results.count
                    if processedCount.isMultiple(of: 25) {
                        await Task.yield()
                    }
                } catch {
                    LoomLogger.error(
                        .cloud,
                        error: error,
                        message: "Failed to fetch peers from zone \(zone.zoneID.zoneName): "
                    )
                }
            }

            let peers = await peerRecordParser.parse(snapshots)
            sharedPeers = peers.sorted { $0.name < $1.name }
            LoomLogger.cloud("Fetched \(peers.count) shared peers from CloudKit")
        } catch {
            LoomLogger.error(.cloud, error: error, message: "Failed to enumerate shared zones: ")
            lastError = error
        }
    }

    public func removeOwnPeer(deviceID: UUID) async throws {
        guard let container = cloudKitManager.container else { throw LoomCloudKitError.containerUnavailable }

        let recordIDs = try await queryPeerRecordIDs(
            database: container.privateCloudDatabase,
            zoneID: peerZoneID,
            deviceID: deviceID
        )

        if recordIDs.isEmpty {
            ownPeers.removeAll { $0.id == deviceID }
            return
        }

        _ = try await container.privateCloudDatabase.modifyRecords(
            saving: [],
            deleting: recordIDs
        )
        ownPeers.removeAll { $0.id == deviceID }
        LoomLogger.cloud("Removed own CloudKit peer record(s) for \(deviceID)")
    }

    public func removeSharedPeer(deviceID: UUID) async throws {
        guard let container = cloudKitManager.container else { throw LoomCloudKitError.containerUnavailable }

        let database = container.sharedCloudDatabase
        let zones = try await database.allRecordZones()
        var deletedRecord = false

        for zone in zones {
            let recordIDs = try await queryPeerRecordIDs(
                database: database,
                zoneID: zone.zoneID,
                deviceID: deviceID
            )
            guard !recordIDs.isEmpty else { continue }

            _ = try await database.modifyRecords(
                saving: [],
                deleting: recordIDs
            )
            deletedRecord = true
        }

        if !deletedRecord {
            throw LoomCloudKitPeerProviderError.sharedPeerNotFound(deviceID: deviceID)
        }

        sharedPeers.removeAll { $0.id == deviceID }
        LoomLogger.cloud("Removed shared CloudKit peer record(s) for \(deviceID)")
    }

    public func removePeer(_ peer: LoomCloudKitPeerInfo) async throws {
        if peer.isShared {
            try await removeSharedPeer(deviceID: peer.id)
        } else {
            try await removeOwnPeer(deviceID: peer.id)
        }
    }

    private func makeSnapshots(
        from results: [(CKRecord.ID, Result<CKRecord, any Error>)],
        isShared: Bool,
        ownerUserID: String?
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
                    bootstrapMetadataBlob: record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] as? Data,
                    lastSeen: record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] as? Date,
                    isShared: isShared,
                    ownerUserID: ownerUserID
                )
            )
        }
        return snapshots
    }

    private func queryPeerRecordIDs(
        database: CKDatabase,
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
        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        return results.compactMap { _, result in
            try? result.get().recordID
        }
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
    let bootstrapMetadataBlob: Data?
    let lastSeen: Date?
    let isShared: Bool
    let ownerUserID: String?
}

private actor PeerRecordSnapshotParser {
    func parse(_ snapshots: [PeerRecordSnapshot]) -> [LoomCloudKitPeerInfo] {
        snapshots.compactMap(parsePeerRecord)
    }

    private func parsePeerRecord(_ snapshot: PeerRecordSnapshot) -> LoomCloudKitPeerInfo? {
        guard let rawDeviceID = snapshot.deviceIDString,
              let deviceID = UUID(uuidString: rawDeviceID) else {
            LoomLogger.cloud("Skipping peer record with invalid deviceID: \(snapshot.recordID)")
            return nil
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

        return LoomCloudKitPeerInfo(
            id: deviceID,
            name: snapshot.name ?? "Unknown Peer",
            deviceType: deviceType,
            advertisement: advertisement,
            lastSeen: snapshot.lastSeen ?? Date.distantPast,
            ownerUserID: snapshot.ownerUserID,
            isShared: snapshot.isShared,
            recordID: snapshot.recordID,
            identityPublicKey: snapshot.identityPublicKey,
            remoteAccessEnabled: snapshot.remoteAccessEnabled ?? false,
            bootstrapMetadata: bootstrapMetadata
        )
    }
}

public enum LoomCloudKitPeerProviderError: LocalizedError, Sendable {
    case sharedPeerNotFound(deviceID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .sharedPeerNotFound(deviceID):
            "Shared peer \(deviceID.uuidString) was not found in accepted CloudKit shares."
        }
    }
}
