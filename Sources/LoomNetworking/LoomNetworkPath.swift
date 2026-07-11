//
//  LoomNetworkPath.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// High-level reachability status reported by a transport backend.
public enum LoomNetworkPathStatus: String, Codable, Hashable, Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

/// A backend-independent snapshot of a network route.
public struct LoomNetworkPath: Codable, Equatable, Sendable {
    public let status: LoomNetworkPathStatus
    public let interfaces: [LoomNetworkInterface]
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let usesWiFi: Bool
    public let usesWiredEthernet: Bool
    public let usesCellular: Bool
    public let usesLoopback: Bool
    public let usesOther: Bool
    public let localEndpoint: LoomNetworkEndpoint?
    public let remoteEndpoint: LoomNetworkEndpoint?

    public init(
        status: LoomNetworkPathStatus,
        interfaces: [LoomNetworkInterface],
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        usesWiFi: Bool,
        usesWiredEthernet: Bool,
        usesCellular: Bool,
        usesLoopback: Bool,
        usesOther: Bool,
        localEndpoint: LoomNetworkEndpoint? = nil,
        remoteEndpoint: LoomNetworkEndpoint? = nil
    ) {
        self.status = status
        self.interfaces = interfaces
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
