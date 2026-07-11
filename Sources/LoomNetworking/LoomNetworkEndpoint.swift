//
//  LoomNetworkEndpoint.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// A host name or numeric address used by a Loom transport backend.
///
/// The value is intentionally preserved verbatim. In particular, scoped IPv6
/// addresses retain their zone identifier so the selected interface is not
/// lost while an endpoint crosses a backend boundary.
public struct LoomNetworkHost: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    public var description: String {
        rawValue
    }
}

/// A backend-independent network endpoint.
///
/// Loom's direct transports use host/port endpoints. Service endpoints retain
/// the DNS-SD identity and optional interface scope until a platform backend
/// resolves them.
public enum LoomNetworkEndpoint: Codable, Hashable, Sendable {
    case hostPort(host: LoomNetworkHost, port: UInt16)
    case service(name: String, type: String, domain: String, interfaceName: String?)
    /// A platform endpoint retained for compatibility but not usable by a
    /// backend that cannot interpret its native representation.
    case opaque(description: String)

    public var hostPort: (host: LoomNetworkHost, port: UInt16)? {
        guard case let .hostPort(host, port) = self else { return nil }
        return (host, port)
    }

    public var service: (name: String, type: String, domain: String, interfaceName: String?)? {
        guard case let .service(name, type, domain, interfaceName) = self else { return nil }
        return (name, type, domain, interfaceName)
    }
}

extension LoomNetworkEndpoint: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .hostPort(host, port):
            let renderedHost = host.rawValue.contains(":") &&
                !host.rawValue.hasPrefix("[") &&
                !host.rawValue.hasSuffix("]")
                ? "[\(host.rawValue)]"
                : host.rawValue
            return "\(renderedHost):\(port)"
        case let .service(name, type, domain, interfaceName):
            let qualifiedName = [name, type, domain]
                .filter { !$0.isEmpty }
                .joined(separator: ".")
            guard let interfaceName, !interfaceName.isEmpty else {
                return qualifiedName
            }
            return "\(qualifiedName)%\(interfaceName)"
        case let .opaque(description):
            return description
        }
    }
}
