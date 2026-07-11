//
//  LoomSessionNetworkPathSnapshot.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/13/26.
//

import Foundation
#if canImport(Network)
import Network
#endif

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
    public let backendLocalEndpoint: LoomNetworkEndpoint?
    public let backendRemoteEndpoint: LoomNetworkEndpoint?

#if canImport(Network)
    /// Network.framework compatibility projection of the local endpoint.
    public var localEndpoint: NWEndpoint? {
        backendLocalEndpoint?.nwEndpoint
    }

    /// Network.framework compatibility projection of the remote endpoint.
    public var remoteEndpoint: NWEndpoint? {
        backendRemoteEndpoint?.nwEndpoint
    }
#endif

    /// Backend-independent representation of this path snapshot.
    public var backendPath: LoomNetworkPath {
        let backendStatus: LoomNetworkPathStatus = switch status {
        case .satisfied:
            .satisfied
        case .unsatisfied:
            .unsatisfied
        case .requiresConnection:
            .requiresConnection
        }
        return LoomNetworkPath(
            status: backendStatus,
            interfaces: interfaceNames.map {
                LoomNetworkInterface(name: $0, type: .other)
            },
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            usesWiFi: usesWiFi,
            usesWiredEthernet: usesWiredEthernet,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther,
            localEndpoint: backendLocalEndpoint,
            remoteEndpoint: backendRemoteEndpoint
        )
    }

    /// Creates a path snapshot without exposing a platform networking type.
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
        backendLocalEndpoint: LoomNetworkEndpoint?,
        backendRemoteEndpoint: LoomNetworkEndpoint?
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
        self.backendLocalEndpoint = backendLocalEndpoint
        self.backendRemoteEndpoint = backendRemoteEndpoint
    }

#if canImport(Network)
    /// Creates a path snapshot using the released Network.framework endpoint API.
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
        self.init(
            status: status,
            interfaceNames: interfaceNames,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            usesWiFi: usesWiFi,
            usesWiredEthernet: usesWiredEthernet,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther,
            backendLocalEndpoint: localEndpoint.flatMap(LoomNetworkEndpoint.init),
            backendRemoteEndpoint: remoteEndpoint.flatMap(LoomNetworkEndpoint.init)
        )
    }
#endif
}

extension LoomSessionNetworkPathSnapshot {
    package init(backendPath: LoomNetworkPath) {
        let status: LoomSessionNetworkPathStatus = switch backendPath.status {
        case .satisfied:
            .satisfied
        case .unsatisfied:
            .unsatisfied
        case .requiresConnection:
            .requiresConnection
        }
        self.init(
            status: status,
            interfaceNames: backendPath.interfaces.map(\.name).sorted(),
            isExpensive: backendPath.isExpensive,
            isConstrained: backendPath.isConstrained,
            supportsIPv4: backendPath.supportsIPv4,
            supportsIPv6: backendPath.supportsIPv6,
            usesWiFi: backendPath.usesWiFi,
            usesWiredEthernet: backendPath.usesWiredEthernet,
            usesCellular: backendPath.usesCellular,
            usesLoopback: backendPath.usesLoopback,
            usesOther: backendPath.usesOther,
            backendLocalEndpoint: backendPath.localEndpoint,
            backendRemoteEndpoint: backendPath.remoteEndpoint
        )
    }

#if canImport(Network)
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
#endif
}
