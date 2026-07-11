//
//  LoomDirectConnectionPolicy.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 3/10/26.
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
    /// Preferred order for direct transport protocols.
    public var preferredTransportOrder: [LoomTransportKind]
    /// Optional host override for nearby DNS-SD-discovered direct transports.
    public var localDiscoveryHostOverride: String?
    /// Whether nearby direct candidates should be treated as a race set by the coordinator.
    public var racesLocalCandidates: Bool
    /// Whether remote direct candidates should be treated as a race set by the coordinator.
    public var racesRemoteCandidates: Bool

    public init(
        preferredLocalPathOrder: [LoomDirectPathKind] = [.wired, .wifi, .awdl, .other],
        preferredTransportOrder: [LoomTransportKind] = [.udp, .tcp],
        localDiscoveryHostOverride: String? = nil,
        racesLocalCandidates: Bool = true,
        racesRemoteCandidates: Bool = true
    ) {
        self.preferredLocalPathOrder = preferredLocalPathOrder
        self.preferredTransportOrder = preferredTransportOrder
        self.localDiscoveryHostOverride = localDiscoveryHostOverride
        self.racesLocalCandidates = racesLocalCandidates
        self.racesRemoteCandidates = racesRemoteCandidates
    }

    public static let `default` = LoomDirectConnectionPolicy()
}
