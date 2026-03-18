//
//  LoomContainerConfiguration.swift
//  LoomKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation
import Loom
import LoomCloudKit

/// Trust behavior used by the SwiftUI-first LoomKit container runtime.
public enum LoomTrustMode: String, Codable, Sendable {
    /// Require explicit local trust decisions before a peer is accepted.
    case manualOnly
    /// Auto-trust peers that resolve to the same iCloud account.
    case sameAccountAutoTrust
    /// Auto-trust peers that are visible through an accepted CloudKit share.
    case shareAwareAutoTrust
}

/// Configuration for a shared LoomKit runtime container.
public struct LoomContainerConfiguration: Sendable {
    /// Async provider used to resolve app-owned bootstrap metadata before publication.
    public typealias BootstrapMetadataProvider = @Sendable () async throws -> LoomBootstrapMetadata?

    /// Bonjour service type used for nearby discovery and advertising.
    public let serviceType: String
    /// Display name advertised for the current device.
    public let serviceName: String
    /// Optional shared `UserDefaults` suite used for stable device identity and trust state.
    public let deviceIDSuiteName: String?
    /// Optional CloudKit configuration used to merge shared peers into the runtime.
    public let cloudKit: LoomCloudKitConfiguration?
    /// Optional overlay directory configuration used for off-LAN peer discovery.
    public let overlayDirectory: LoomOverlayDirectoryConfiguration?
    /// Optional remote signaling configuration used for remote reachability publication and remote joins.
    public let remoteSignaling: LoomRemoteSignalingConfiguration?
    /// Optional macOS App Group configuration used to share one Loom runtime across multiple apps.
    public let appGroup: LoomAppGroupConfiguration?
    /// Trust policy applied when evaluating nearby and CloudKit-backed peers.
    public let trust: LoomTrustMode
    /// Enables Bonjour peer-to-peer discovery when available on the platform.
    public let enablePeerToPeer: Bool
    /// App-defined metadata published with the local advertisement.
    public let advertisementMetadata: [String: String]
    /// Feature flags advertised for compatibility filtering.
    public let supportedFeatures: [String]
    /// App-defined provider for optional bootstrap metadata.
    public let bootstrapMetadataProvider: BootstrapMetadataProvider?
    /// Optional remote signaling session ID to publish immediately after start.
    public let remoteSessionID: String?
    /// Transfer-engine tuning used for outgoing and incoming bulk transfers.
    public let transferConfiguration: LoomTransferConfiguration
    /// Policy used when racing direct candidates before signaling fallback.
    public let directConnectionPolicy: LoomDirectConnectionPolicy

    /// Creates a SwiftUI-first LoomKit runtime configuration.
    public init(
        serviceType: String = Loom.serviceType,
        serviceName: String,
        deviceIDSuiteName: String? = nil,
        cloudKit: LoomCloudKitConfiguration? = nil,
        overlayDirectory: LoomOverlayDirectoryConfiguration? = nil,
        remoteSignaling: LoomRemoteSignalingConfiguration? = nil,
        appGroup: LoomAppGroupConfiguration? = nil,
        trust: LoomTrustMode = .manualOnly,
        enablePeerToPeer: Bool = true,
        advertisementMetadata: [String: String] = [:],
        supportedFeatures: [String] = [],
        bootstrapMetadataProvider: BootstrapMetadataProvider? = nil,
        remoteSessionID: String? = nil,
        transferConfiguration: LoomTransferConfiguration = .default,
        directConnectionPolicy: LoomDirectConnectionPolicy = .default
    ) {
        self.serviceType = serviceType
        self.serviceName = serviceName
        self.deviceIDSuiteName = deviceIDSuiteName
        self.cloudKit = cloudKit
        self.overlayDirectory = overlayDirectory
        self.remoteSignaling = remoteSignaling
        self.appGroup = appGroup
        self.trust = trust
        self.enablePeerToPeer = enablePeerToPeer
        self.advertisementMetadata = advertisementMetadata
        self.supportedFeatures = Array(
            Set(
                supportedFeatures
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
        self.bootstrapMetadataProvider = bootstrapMetadataProvider
        self.remoteSessionID = remoteSessionID
        self.transferConfiguration = transferConfiguration
        self.directConnectionPolicy = directConnectionPolicy
    }
}
