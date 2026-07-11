//
//  LoomDNSServiceDiscovery.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Stable DNS-SD service identity, including optional interface scope.
public struct LoomDNSServiceIdentity: Codable, Hashable, Sendable {
    public let name: String
    public let type: String
    public let domain: String
    public let interfaceIndex: UInt32?

    public init(
        name: String,
        type: String,
        domain: String = "local",
        interfaceIndex: UInt32? = nil
    ) {
        self.name = name
        self.type = Self.normalize(type, defaultValue: "")
        self.domain = Self.normalize(domain, defaultValue: "local")
        self.interfaceIndex = interfaceIndex == 0 ? nil : interfaceIndex
    }

    public var queryName: String {
        "\(type).\(domain)"
    }

    public var fullyQualifiedName: String {
        "\(Self.escapeLabel(name)).\(queryName)"
    }

    /// Parses a DNS presentation-format service instance without losing Unicode labels.
    public init?(fullyQualifiedName: String, interfaceIndex: UInt32? = nil) {
        guard let firstSeparator = Self.firstUnescapedDot(in: fullyQualifiedName) else { return nil }
        let escapedName = String(fullyQualifiedName[..<firstSeparator])
        let remainderStart = fullyQualifiedName.index(after: firstSeparator)
        let remainder = String(fullyQualifiedName[remainderStart...])
        let components = remainder.split(separator: ".", omittingEmptySubsequences: true)
        guard components.count >= 3 else { return nil }
        let type = components.prefix(2).joined(separator: ".")
        let domain = components.dropFirst(2).joined(separator: ".")
        guard let name = Self.unescapeLabel(escapedName) else { return nil }
        self.init(name: name, type: type, domain: domain, interfaceIndex: interfaceIndex)
    }

    private static func normalize(_ value: String, defaultValue: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized.isEmpty ? defaultValue : normalized
    }

    private static func escapeLabel(_ label: String) -> String {
        var result = ""
        result.reserveCapacity(label.utf8.count)
        for character in label {
            if character == "." || character == "\\" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private static func firstUnescapedDot(in value: String) -> String.Index? {
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "." {
                return index
            }
        }
        return nil
    }

    private static func unescapeLabel(_ label: String) -> String? {
        let source = Array(label.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            guard source[index] == UInt8(ascii: "\\") else {
                result.append(source[index])
                index += 1
                continue
            }
            index += 1
            guard index < source.count else { return nil }
            if index + 2 < source.count,
               source[index ... index + 2].allSatisfy({ $0 >= 48 && $0 <= 57 }) {
                let value = Int(source[index] - 48) * 100 +
                    Int(source[index + 1] - 48) * 10 +
                    Int(source[index + 2] - 48)
                guard let byte = UInt8(exactly: value) else { return nil }
                result.append(byte)
                index += 3
            } else {
                result.append(source[index])
                index += 1
            }
        }
        return String(bytes: result, encoding: .utf8)
    }
}

/// A resolved DNS-SD service and its exact TXT value bytes.
public struct LoomDNSServiceInstance: Hashable, Sendable {
    public let identity: LoomDNSServiceIdentity
    public let hostName: String?
    public let addresses: [LoomNetworkHost]
    public let port: UInt16
    public let txtRecord: LoomTXTRecord
    public let timeToLive: UInt32?

    public init(
        identity: LoomDNSServiceIdentity,
        hostName: String?,
        addresses: [LoomNetworkHost],
        port: UInt16,
        txtRecord: LoomTXTRecord,
        timeToLive: UInt32? = nil
    ) {
        self.identity = identity
        self.hostName = hostName
        self.addresses = addresses
        self.port = port
        self.txtRecord = txtRecord
        self.timeToLive = timeToLive
    }
}

/// Lifecycle events from a DNS-SD browser backend.
public enum LoomDNSServiceBrowserEvent: Sendable {
    case ready
    case added(LoomDNSServiceInstance)
    case changed(LoomDNSServiceInstance)
    case removed(LoomDNSServiceIdentity)
    case failed(LoomNetworkError)
    case cancelled
}

/// Configuration shared by DNS-SD advertiser and browser implementations.
public struct LoomDNSServiceConfiguration: Hashable, Sendable {
    public var serviceType: String
    public var domain: String
    public var interfaceIndex: UInt32?
    public var includePeerToPeer: Bool

    public init(
        serviceType: String,
        domain: String = "local",
        interfaceIndex: UInt32? = nil,
        includePeerToPeer: Bool = false
    ) {
        self.serviceType = serviceType
        self.domain = domain
        self.interfaceIndex = interfaceIndex == 0 ? nil : interfaceIndex
        self.includePeerToPeer = includePeerToPeer
    }
}

public protocol LoomDNSServiceBrowser: Sendable {
    func start() async throws
    func makeEventStream() async -> AsyncStream<LoomDNSServiceBrowserEvent>
    func cancel() async
}

public protocol LoomDNSServiceAdvertiser: Sendable {
    func start() async throws
    func updateTXTRecord(_ txtRecord: LoomTXTRecord) async throws
    func cancel() async
}

/// Factory boundary for platform DNS-SD implementations.
public protocol LoomDNSServiceBackend: Sendable {
    func makeBrowser(configuration: LoomDNSServiceConfiguration) throws -> any LoomDNSServiceBrowser

    func makeAdvertiser(
        identity: LoomDNSServiceIdentity,
        hostName: String?,
        port: UInt16,
        txtRecord: LoomTXTRecord
    ) throws -> any LoomDNSServiceAdvertiser
}
