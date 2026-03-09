//
//  LoomCloudKitTrustProvider.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  iCloud-based trust provider for automatic device approval.
//

import Foundation
import Loom

/// iCloud-based trust provider that auto-approves devices on the same iCloud account
/// or devices belonging to friends via CloudKit sharing.
///
/// This provider implements a layered trust evaluation:
///
/// 1. If ``requireApprovalForAllConnections`` is enabled → `.requiresApproval`
/// 2. If device is in the local trust store → `.trusted`
/// 3. If peer has no iCloud identity → `.requiresApproval`
/// 4. If CloudKit is unavailable → `.unavailable`
/// 5. If peer is on same iCloud account → `.trusted`
/// 6. If peer is a share participant (friend) → `.trusted`
/// 7. Otherwise → `.requiresApproval`
///
/// ## Usage
///
/// ```swift
/// let cloudKitManager = LoomCloudKitManager(
///     containerIdentifier: "iCloud.com.yourcompany.YourApp"
/// )
/// let trustProvider = LoomCloudKitTrustProvider(
///     cloudKitManager: cloudKitManager,
///     localTrustStore: trustStore
/// )
/// hostService.trustProvider = trustProvider
/// ```
@MainActor
public final class LoomCloudKitTrustProvider: LoomTrustProvider {
    // MARK: - Properties

    /// CloudKit manager for user identity and share checking.
    private let cloudKitManager: LoomCloudKitManager

    /// Local trust store fallback for devices without iCloud.
    private let localTrustStore: LoomTrustStore

    /// Whether to require approval for all connections regardless of iCloud status.
    ///
    /// When enabled, even devices on the same iCloud account or share participants
    /// will require manual approval. Use this for high-security scenarios.
    public var requireApprovalForAllConnections: Bool = false

    // MARK: - Initialization

    /// Creates a CloudKit-based trust provider.
    ///
    /// - Parameters:
    ///   - cloudKitManager: The CloudKit manager for identity and share checking.
    ///   - localTrustStore: Local trust store for manually approved devices.
    public init(cloudKitManager: LoomCloudKitManager, localTrustStore: LoomTrustStore) {
        self.cloudKitManager = cloudKitManager
        self.localTrustStore = localTrustStore
    }

    // MARK: - LoomTrustProvider

    public nonisolated func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        await evaluateTrustOutcomeOnMain(for: peer).decision
    }

    public nonisolated func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        await evaluateTrustOutcomeOnMain(for: peer)
    }

    @MainActor
    private func evaluateTrustOutcomeOnMain(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        // Check settings override first
        if requireApprovalForAllConnections {
            LoomLogger.trust("Trust evaluation: approval required by settings for \(peer.name)")
            return LoomTrustEvaluation(decision: .requiresApproval, shouldShowAutoTrustNotice: false)
        }

        guard peer.isIdentityAuthenticated else {
            LoomLogger.trust("Trust evaluation: denied unauthenticated identity for \(peer.name)")
            return LoomTrustEvaluation(decision: .denied, shouldShowAutoTrustNotice: false)
        }
        guard let peerIdentityKeyID = peer.identityKeyID else {
            LoomLogger.trust("Trust evaluation: denied missing identity key ID for \(peer.name)")
            return LoomTrustEvaluation(decision: .denied, shouldShowAutoTrustNotice: false)
        }
        if let publicKey = peer.identityPublicKey,
           LoomIdentityManager.keyID(for: publicKey) != peerIdentityKeyID {
            LoomLogger.trust("Trust evaluation: denied mismatched key ID for \(peer.name)")
            return LoomTrustEvaluation(decision: .denied, shouldShowAutoTrustNotice: false)
        }

        // Check if locally trusted (overrides everything)
        if localTrustStore.isTrusted(deviceID: peer.deviceID) {
            LoomLogger.trust("Trust evaluation: device \(peer.name) is locally trusted")
            return LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
        }

        // No iCloud identity means we can't auto-trust
        guard let peerUserID = peer.iCloudUserID else {
            LoomLogger.trust("Trust evaluation: no iCloud identity for \(peer.name)")
            return LoomTrustEvaluation(decision: .requiresApproval, shouldShowAutoTrustNotice: false)
        }

        // Check if CloudKit is available
        guard cloudKitManager.isAvailable else {
            LoomLogger.trust("Trust evaluation: CloudKit unavailable, falling back to approval")
            return LoomTrustEvaluation(
                decision: .unavailable("iCloud not available"),
                shouldShowAutoTrustNotice: false
            )
        }

        // Check if same iCloud account
        if let myUserID = cloudKitManager.currentUserRecordID, peerUserID == myUserID {
            LoomLogger.trust("Trust evaluation: same iCloud account for \(peer.name)")
            return LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: true)
        }

        // Check if peer is a share participant (friend)
        let isParticipant = await cloudKitManager.isShareParticipant(userID: peerUserID)
        if isParticipant {
            let identityTrusted = await cloudKitManager.isShareParticipantIdentityKeyTrusted(keyID: peerIdentityKeyID)
            if identityTrusted {
                LoomLogger.trust("Trust evaluation: share participant identity trusted for \(peer.name)")
                return LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
            }
            LoomLogger.trust("Trust evaluation: share participant missing trusted identity key for \(peer.name)")
            return LoomTrustEvaluation(decision: .requiresApproval, shouldShowAutoTrustNotice: false)
        }

        // Unknown user - require approval
        LoomLogger.trust("Trust evaluation: unknown iCloud user, requiring approval for \(peer.name)")
        return LoomTrustEvaluation(decision: .requiresApproval, shouldShowAutoTrustNotice: false)
    }

    public nonisolated func grantTrust(to peer: LoomPeerIdentity) async throws {
        await MainActor.run {
            // Add to local trust store
            let device = LoomTrustedDevice(
                id: peer.deviceID,
                name: peer.name,
                deviceType: peer.deviceType,
                trustedAt: Date()
            )
            localTrustStore.addTrustedDevice(device)
            LoomLogger.trust("Granted trust to \(peer.name)")
        }
    }

    public nonisolated func revokeTrust(for deviceID: UUID) async throws {
        await MainActor.run {
            if let device = localTrustStore.trustedDevices.first(where: { $0.id == deviceID }) {
                localTrustStore.revokeTrust(for: device)
                LoomLogger.trust("Revoked trust for device \(deviceID)")
            }
        }
    }
}
