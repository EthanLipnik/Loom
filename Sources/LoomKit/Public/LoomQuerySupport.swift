//
//  LoomQuerySupport.swift
//  LoomKit
//
//  Created by Codex on 3/11/26.
//

import Foundation

/// Built-in peer filters supported by ``LoomQuery``.
public enum LoomPeerFilter: Sendable {
    /// Include all peer snapshots.
    case all
    /// Include only peers currently visible nearby.
    case nearby
    /// Include only peers currently visible through the overlay directory.
    case overlay
    /// Include only peers visible through a shared CloudKit graph.
    case shared
    /// Include only peers that currently advertise relay-backed remote access.
    case remoteAccessEnabled
}

/// Built-in peer sorting supported by ``LoomQuery``.
public enum LoomPeerSort: Sendable {
    /// Sort peers alphabetically by display name.
    case name
    /// Sort peers by device family, then by name.
    case deviceType
    /// Sort peers by freshest observation first.
    case lastSeenDescending
}

/// Built-in connection filters supported by ``LoomQuery``.
public enum LoomConnectionFilter: Sendable {
    /// Include all connection snapshots.
    case all
    /// Include only connected sessions.
    case connected
    /// Include only failed sessions.
    case failed
}

/// Built-in connection sorting supported by ``LoomQuery``.
public enum LoomConnectionSort: Sendable {
    /// Sort newest connections first.
    case connectedAtDescending
    /// Sort connections alphabetically by peer name.
    case peerName
}

/// Built-in transfer filters supported by ``LoomQuery``.
public enum LoomTransferFilter: Sendable {
    /// Include all transfer snapshots.
    case all
    /// Include only incoming transfers.
    case incoming
    /// Include only outgoing transfers.
    case outgoing
    /// Include only currently active transfers.
    case active
}

/// Built-in transfer sorting supported by ``LoomQuery``.
public enum LoomTransferSort: Sendable {
    /// Sort transfers alphabetically by logical name.
    case logicalName
    /// Sort transfers by completion ratio from highest to lowest.
    case progressDescending
}

/// Descriptor used to configure a ``LoomQuery``.
public enum LoomQueryDescriptor: Sendable {
    /// Query peer snapshots from the current ``LoomContext``.
    case peers(filter: LoomPeerFilter = .all, sort: LoomPeerSort = .name)
    /// Query connection snapshots from the current ``LoomContext``.
    case connections(filter: LoomConnectionFilter = .all, sort: LoomConnectionSort = .connectedAtDescending)
    /// Query transfer snapshots from the current ``LoomContext``.
    case transfers(filter: LoomTransferFilter = .all, sort: LoomTransferSort = .logicalName)
}

package enum LoomQueryEvaluator {
    package static func filterPeers(
        _ peers: [LoomPeerSnapshot],
        filter: LoomPeerFilter
    ) -> [LoomPeerSnapshot] {
        switch filter {
        case .all:
            peers
        case .nearby:
            peers.filter(\.isNearby)
        case .overlay:
            peers.filter { $0.sources.contains(.overlay) }
        case .shared:
            peers.filter(\.isShared)
        case .remoteAccessEnabled:
            peers.filter(\.remoteAccessEnabled)
        }
    }

    package static func sortPeers(
        _ peers: [LoomPeerSnapshot],
        sort: LoomPeerSort
    ) -> [LoomPeerSnapshot] {
        peers.sorted { lhs, rhs in
            switch sort {
            case .name:
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return lhs.id.rawValue < rhs.id.rawValue

            case .deviceType:
                if lhs.deviceType.rawValue != rhs.deviceType.rawValue {
                    return lhs.deviceType.rawValue < rhs.deviceType.rawValue
                }
                return lhs.name < rhs.name

            case .lastSeenDescending:
                if lhs.lastSeen != rhs.lastSeen {
                    return lhs.lastSeen > rhs.lastSeen
                }
                return lhs.name < rhs.name
            }
        }
    }

    package static func filterConnections(
        _ connections: [LoomConnectionSnapshot],
        filter: LoomConnectionFilter
    ) -> [LoomConnectionSnapshot] {
        switch filter {
        case .all:
            connections
        case .connected:
            connections.filter { $0.state == .connected }
        case .failed:
            connections.filter { $0.state == .failed }
        }
    }

    package static func sortConnections(
        _ connections: [LoomConnectionSnapshot],
        sort: LoomConnectionSort
    ) -> [LoomConnectionSnapshot] {
        connections.sorted { lhs, rhs in
            switch sort {
            case .connectedAtDescending:
                if lhs.connectedAt != rhs.connectedAt {
                    return lhs.connectedAt > rhs.connectedAt
                }
                return lhs.peerName < rhs.peerName

            case .peerName:
                if lhs.peerName != rhs.peerName {
                    return lhs.peerName < rhs.peerName
                }
                return lhs.connectedAt > rhs.connectedAt
            }
        }
    }

    package static func filterTransfers(
        _ transfers: [LoomTransferSnapshot],
        filter: LoomTransferFilter
    ) -> [LoomTransferSnapshot] {
        switch filter {
        case .all:
            transfers
        case .incoming:
            transfers.filter { $0.direction == .incoming }
        case .outgoing:
            transfers.filter { $0.direction == .outgoing }
        case .active:
            transfers.filter {
                switch $0.state {
                case .offered,
                     .waitingForAcceptance,
                     .transferring:
                    true
                case .completed,
                     .cancelled,
                     .failed,
                     .declined:
                    false
                }
            }
        }
    }

    package static func sortTransfers(
        _ transfers: [LoomTransferSnapshot],
        sort: LoomTransferSort
    ) -> [LoomTransferSnapshot] {
        transfers.sorted { lhs, rhs in
            switch sort {
            case .logicalName:
                if lhs.logicalName != rhs.logicalName {
                    return lhs.logicalName < rhs.logicalName
                }
                return lhs.id.uuidString < rhs.id.uuidString

            case .progressDescending:
                let leftRatio = lhs.totalBytes == 0 ? 0 : Double(lhs.bytesTransferred) / Double(lhs.totalBytes)
                let rightRatio = rhs.totalBytes == 0 ? 0 : Double(rhs.bytesTransferred) / Double(rhs.totalBytes)
                if leftRatio != rightRatio {
                    return leftRatio > rightRatio
                }
                return lhs.logicalName < rhs.logicalName
            }
        }
    }
}
