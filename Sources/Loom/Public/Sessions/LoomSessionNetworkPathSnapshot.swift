//
//  LoomSessionNetworkPathSnapshot.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/13/26.
//

import Foundation
import Network

/// High-level reachability status for an authenticated Loom session transport path.
public enum LoomSessionNetworkPathStatus: String, Sendable, Codable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

/// Snapshot of the transport path currently used by an authenticated Loom session.
public struct LoomSessionNetworkPathSnapshot: Sendable, Equatable {
    public let status: LoomSessionNetworkPathStatus
    public let interfaceNames: [String]
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let usesWiFi: Bool
    public let usesWiredEthernet: Bool
    public let usesCellular: Bool
    public let usesLoopback: Bool
    public let usesOther: Bool
    public let localEndpoint: NWEndpoint?
    public let remoteEndpoint: NWEndpoint?

    public init(
        status: LoomSessionNetworkPathStatus,
        interfaceNames: [String],
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        usesWiFi: Bool,
        usesWiredEthernet: Bool,
        usesCellular: Bool,
        usesLoopback: Bool,
        usesOther: Bool,
        localEndpoint: NWEndpoint?,
        remoteEndpoint: NWEndpoint?
    ) {
        self.status = status
        self.interfaceNames = interfaceNames
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.usesWiFi = usesWiFi
        self.usesWiredEthernet = usesWiredEthernet
        self.usesCellular = usesCellular
        self.usesLoopback = usesLoopback
        self.usesOther = usesOther
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
    }
}

extension LoomSessionNetworkPathSnapshot {
    package init(path: NWPath) {
        let status: LoomSessionNetworkPathStatus = switch path.status {
        case .satisfied:
            .satisfied
        case .unsatisfied:
            .unsatisfied
        case .requiresConnection:
            .requiresConnection
        @unknown default:
            .requiresConnection
        }

        self.init(
            status: status,
            interfaceNames: path.availableInterfaces.map(\.name).sorted(),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            usesCellular: path.usesInterfaceType(.cellular),
            usesLoopback: path.usesInterfaceType(.loopback),
            usesOther: path.usesInterfaceType(.other),
            localEndpoint: path.localEndpoint,
            remoteEndpoint: path.remoteEndpoint
        )
    }
}
