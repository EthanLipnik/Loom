//
//  LoomDirectConnectionPolicy.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import Foundation

/// Broad path categories used when preferring one direct route over another.
public enum LoomDirectPathKind: String, Codable, CaseIterable, Sendable {
    case wired
    case wifi
    case awdl
    case other
}

/// Policy used to rank nearby and remote direct transport candidates.
public struct LoomDirectConnectionPolicy: Sendable, Hashable {
    /// Preferred order for nearby path categories when direct path hints are available.
    public var preferredLocalPathOrder: [LoomDirectPathKind]
    /// Preferred order for direct transport protocols published by remote signaling.
    public var preferredRemoteTransportOrder: [LoomTransportKind]
    /// Whether nearby direct candidates should be treated as a race set by the coordinator.
    public var racesLocalCandidates: Bool
    /// Whether remote direct candidates should be treated as a race set by the coordinator.
    public var racesRemoteCandidates: Bool

    /// Creates a direct connection policy for Loom-owned path and transport ranking.
    public init(
        preferredLocalPathOrder: [LoomDirectPathKind] = [.wired, .wifi, .awdl, .other],
        preferredRemoteTransportOrder: [LoomTransportKind] = [.quic, .tcp],
        racesLocalCandidates: Bool = true,
        racesRemoteCandidates: Bool = true
    ) {
        self.preferredLocalPathOrder = preferredLocalPathOrder
        self.preferredRemoteTransportOrder = preferredRemoteTransportOrder
        self.racesLocalCandidates = racesLocalCandidates
        self.racesRemoteCandidates = racesRemoteCandidates
    }

    public static let `default` = LoomDirectConnectionPolicy()
}
