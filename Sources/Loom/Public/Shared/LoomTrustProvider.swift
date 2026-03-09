//
//  LoomTrustProvider.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Protocol for custom trust resolution in connection approval flows.
//

import Foundation

// MARK: - Trust Decision

/// Result of trust evaluation for a connecting peer.
public enum LoomTrustDecision: Sendable, Equatable {
    /// Auto-approve connection without prompting user.
    case trusted

    /// Show manual approval prompt to user.
    case requiresApproval

    /// Reject connection immediately.
    case denied

    /// Trust provider is offline or encountered an error; fall back to manual approval.
    case unavailable(String)

    public static func == (lhs: LoomTrustDecision, rhs: LoomTrustDecision) -> Bool {
        switch (lhs, rhs) {
        case (.trusted, .trusted): true
        case (.requiresApproval, .requiresApproval): true
        case (.denied, .denied): true
        case let (.unavailable(a), .unavailable(b)): a == b
        default: false
        }
    }
}

/// Trust evaluation metadata used by peer connection flows.
public struct LoomTrustEvaluation: Sendable, Equatable {
    /// Final trust decision for the incoming peer.
    public let decision: LoomTrustDecision

    /// Whether the caller should present the one-time auto-trust notice.
    public let shouldShowAutoTrustNotice: Bool

    /// Creates trust decision metadata for connection approval flows.
    ///
    /// - Parameters:
    ///   - decision: Trust decision for the connecting peer.
    ///   - shouldShowAutoTrustNotice: Whether callers should show a one-time auto-trust notice.
    public init(decision: LoomTrustDecision, shouldShowAutoTrustNotice: Bool) {
        self.decision = decision
        self.shouldShowAutoTrustNotice = shouldShowAutoTrustNotice
    }
}

// MARK: - Peer Identity

/// Extended device identity with optional iCloud information.
///
/// Contains all identifying information about a connecting peer, including
/// the optional iCloud user ID for same-account and friend-share trust evaluation.
public struct LoomPeerIdentity: Sendable {
    /// Unique device identifier.
    public let deviceID: UUID

    /// Display name of the device.
    public let name: String

    /// Type of device (Mac, iPad, iPhone, Vision).
    public let deviceType: DeviceType

    /// iCloud user record ID (CKRecord.ID.recordName), if available.
    /// Used to determine if the peer is on the same iCloud account or is a share participant.
    public let iCloudUserID: String?

    /// Identity key identifier from the signed handshake.
    public let identityKeyID: String?

    /// Identity public key from the signed handshake.
    public let identityPublicKey: Data?

    /// Whether the handshake identity was cryptographically validated.
    public let isIdentityAuthenticated: Bool

    /// Network endpoint description (IP address or hostname).
    public let endpoint: String

    /// Creates a peer identity payload used by trust providers.
    ///
    /// - Parameters:
    ///   - deviceID: Unique peer device identifier.
    ///   - name: Peer display name.
    ///   - deviceType: Peer platform classification.
    ///   - iCloudUserID: Optional iCloud user identifier.
    ///   - identityKeyID: Optional handshake identity key identifier.
    ///   - identityPublicKey: Optional handshake identity public key bytes.
    ///   - isIdentityAuthenticated: Whether handshake identity verification succeeded.
    ///   - endpoint: Human-readable endpoint description.
    public init(
        deviceID: UUID,
        name: String,
        deviceType: DeviceType,
        iCloudUserID: String?,
        identityKeyID: String?,
        identityPublicKey: Data?,
        isIdentityAuthenticated: Bool,
        endpoint: String
    ) {
        self.deviceID = deviceID
        self.name = name
        self.deviceType = deviceType
        self.iCloudUserID = iCloudUserID
        self.identityKeyID = identityKeyID
        self.identityPublicKey = identityPublicKey
        self.isIdentityAuthenticated = isIdentityAuthenticated
        self.endpoint = endpoint
    }
}

// MARK: - Trust Provider Protocol

/// Protocol for custom trust resolution during connection approval.
///
/// Implement this protocol to provide custom logic for determining whether
/// to auto-trust, prompt for approval, or deny incoming connections.
///
/// The default behavior when no provider is set is to use delegate-based
/// manual approval for all connections.
///
/// Example implementation for iCloud-based trust:
/// ```swift
/// class CloudKitTrustProvider: LoomTrustProvider {
///     func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
///         guard let peerUserID = peer.iCloudUserID else {
///             return .requiresApproval
///         }
///         if peerUserID == myUserID {
///             return .trusted  // Same iCloud account
///         }
///         if isShareParticipant(userID: peerUserID) {
///             return .trusted  // Friend with share access
///         }
///         return .requiresApproval
///     }
/// }
/// ```
public protocol LoomTrustProvider: AnyObject, Sendable {
    /// Evaluates whether to trust a connecting peer.
    ///
    /// - Parameter peer: Identity information about the connecting device.
    /// - Returns: Decision on how to handle the connection.
    @MainActor
    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision

    /// Evaluates trust plus notice metadata for a connecting peer.
    ///
    /// Use this when trust sources need different caller UX behavior (for example,
    /// same-account iCloud auto-trust vs. manually persisted local trust).
    ///
    /// - Parameter peer: Identity information about the connecting device.
    /// - Returns: Decision plus one-time auto-trust notice eligibility.
    @MainActor
    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation

    /// Grants trust to a peer, persisting the decision.
    ///
    /// Called when the user manually approves a connection with "Always Trust" option.
    /// The provider should persist this trust decision for future connections.
    ///
    /// - Parameter peer: Identity of the peer to trust.
    @MainActor
    func grantTrust(to peer: LoomPeerIdentity) async throws

    /// Revokes previously granted trust for a device.
    ///
    /// - Parameter deviceID: Identifier of the device to revoke trust for.
    @MainActor
    func revokeTrust(for deviceID: UUID) async throws
}

public extension LoomTrustProvider {
    /// Default trust outcome adapter built from ``evaluateTrust(for:)``.
    ///
    /// Custom providers can override this to control notice behavior independently from trust decision.
    @MainActor
    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        let decision = await evaluateTrust(for: peer)
        return LoomTrustEvaluation(
            decision: decision,
            shouldShowAutoTrustNotice: decision == .trusted
        )
    }
}
