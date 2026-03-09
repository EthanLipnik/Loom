//
//  LoomCloudKitConfiguration.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Configuration for CloudKit-based trust and sharing.
//

import Foundation
import Loom

/// Configuration for Loom CloudKit integration.
///
/// Use this to customize CloudKit behavior for your app. The defaults use
/// "Loom" prefixed names for record types and zones.
///
/// ## CloudKit Setup
///
/// Before using CloudKit features, configure your app in the Apple Developer portal:
///
/// 1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
/// 2. Select your app identifier and enable iCloud with CloudKit
/// 3. Go to [CloudKit Console](https://icloud.developer.apple.com/)
/// 4. Select your container and create the required record types:
///
/// **LoomDevice** (or your custom `deviceRecordType`):
/// - `name` (String) - Device display name
/// - `deviceType` (String) - Device type (mac, iPad, iPhone, vision)
/// - `lastSeen` (Date/Time) - Last activity timestamp
///
/// **LoomPeer** (or your custom `peerRecordType`):
/// - `name` (String) - Peer display name
/// - `createdAt` (Date/Time) - Creation timestamp
///
/// 5. Add indexes for queryable fields (name, deviceType)
/// 6. Deploy schema changes to production
///
public struct LoomCloudKitConfiguration: Sendable {
    /// CloudKit container identifier (e.g., "iCloud.com.yourcompany.YourApp").
    public let containerIdentifier: String

    /// Record type for device registration.
    public let deviceRecordType: String

    /// Record type for peer records used in sharing.
    public let peerRecordType: String

    /// Zone name for peer records.
    public let peerZoneName: String

    /// Record type for shared participant identity metadata.
    public let participantIdentityRecordType: String

    /// Title shown in the CloudKit sharing UI.
    public let shareTitle: String

    /// UserDefaults key for storing the stable device ID.
    public let deviceIDKey: String

    /// Cache TTL for share participants in seconds.
    public let shareParticipantCacheTTL: TimeInterval

    /// Creates a CloudKit configuration with the specified settings.
    ///
    /// - Parameters:
    ///   - containerIdentifier: CloudKit container identifier (required).
    ///   - deviceRecordType: Record type for devices. Defaults to "LoomDevice".
    ///   - peerRecordType: Record type for peers. Defaults to "LoomPeer".
    ///   - peerZoneName: Zone name for peer records. Defaults to "LoomPeerZone".
    ///   - shareTitle: Title for sharing UI. Defaults to "Peer Access".
    ///   - deviceIDKey: UserDefaults key for device ID. Defaults to "com.loom.deviceID".
    ///   - shareParticipantCacheTTL: Cache TTL in seconds. Defaults to 300 (5 minutes).
    public init(
        containerIdentifier: String,
        deviceRecordType: String = "LoomDevice",
        peerRecordType: String = "LoomPeer",
        peerZoneName: String = "LoomPeerZone",
        participantIdentityRecordType: String = "LoomParticipantIdentity",
        shareTitle: String = "Peer Access",
        deviceIDKey: String = "com.loom.deviceID",
        shareParticipantCacheTTL: TimeInterval = 300
    ) {
        self.containerIdentifier = containerIdentifier
        self.deviceRecordType = deviceRecordType
        self.peerRecordType = peerRecordType
        self.peerZoneName = peerZoneName
        self.participantIdentityRecordType = participantIdentityRecordType
        self.shareTitle = shareTitle
        self.deviceIDKey = deviceIDKey
        self.shareParticipantCacheTTL = shareParticipantCacheTTL
    }
}
