//
//  LoomCloudKitPeerInfo.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Peer information retrieved from CloudKit.
//

import Foundation
import Loom

/// Represents a peer stored in CloudKit.
public struct LoomCloudKitPeerInfo: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let deviceType: DeviceType
    public let advertisement: LoomPeerAdvertisement
    public let lastSeen: Date
    public let ownerUserID: String?
    public let isShared: Bool
    public let recordID: String
    public let identityPublicKey: Data?
    public let remoteAccessEnabled: Bool
    public let bootstrapMetadata: LoomBootstrapMetadata?

    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        advertisement: LoomPeerAdvertisement,
        lastSeen: Date,
        ownerUserID: String?,
        isShared: Bool,
        recordID: String,
        identityPublicKey: Data? = nil,
        remoteAccessEnabled: Bool = false,
        bootstrapMetadata: LoomBootstrapMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.advertisement = advertisement
        self.lastSeen = lastSeen
        self.ownerUserID = ownerUserID
        self.isShared = isShared
        self.recordID = recordID
        self.identityPublicKey = identityPublicKey
        self.remoteAccessEnabled = remoteAccessEnabled
        self.bootstrapMetadata = bootstrapMetadata
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: LoomCloudKitPeerInfo, rhs: LoomCloudKitPeerInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - CloudKit Record Keys

public extension LoomCloudKitPeerInfo {
    enum RecordKey: String {
        case deviceID
        case name
        case deviceType
        case advertisementBlob
        case identityPublicKey
        case remoteAccessEnabled
        case bootstrapMetadataBlob
        case lastSeen
        case createdAt
    }
}
