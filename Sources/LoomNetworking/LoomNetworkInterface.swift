//
//  LoomNetworkInterface.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// A backend-independent network-interface category.
///
/// This is an open string-backed value so a platform backend can preserve an
/// interface category introduced after the current Loom release.
public struct LoomNetworkInterfaceType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let wifi = LoomNetworkInterfaceType(rawValue: "wifi")
    public static let wiredEthernet = LoomNetworkInterfaceType(rawValue: "wired-ethernet")
    public static let cellular = LoomNetworkInterfaceType(rawValue: "cellular")
    public static let loopback = LoomNetworkInterfaceType(rawValue: "loopback")
    public static let other = LoomNetworkInterfaceType(rawValue: "other")
}

/// Backend-independent identity and category information for a network interface.
public struct LoomNetworkInterface: Codable, Hashable, Sendable {
    /// System interface name, such as `en0`.
    public let name: String

    /// Platform interface index when one is available.
    public let index: Int?

    /// Broad interface category used for route policy and diagnostics.
    public let type: LoomNetworkInterfaceType

    public init(name: String, index: Int? = nil, type: LoomNetworkInterfaceType) {
        self.name = name
        self.index = index
        self.type = type
    }
}
