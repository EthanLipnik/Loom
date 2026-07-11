//
//  LoomPeer.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
#if canImport(Network)
import Network
#endif

/// Network-interface class inferred from Bonjour discovery metadata.
public enum LoomDiscoveredInterfaceKind: String, Hashable, Sendable {
    case applePrivateNCM
    case awdl
    case lowLatencyWireless
    case wiredEthernet
    case bridge
    case wifi
    case cellular
    case loopback
    case overlay
    case other
}

/// Interface metadata reported by Bonjour discovery for a peer.
public struct LoomDiscoveredInterface: Hashable, Sendable {
    /// System interface name, such as `en0` or `awdl0`.
    public let name: String

    /// Backend-independent interface type.
    public let backendType: LoomNetworkInterfaceType

    /// System interface index.
    public let index: Int

#if canImport(Network)
    private let nativeNetworkInterface: NWInterface?

    /// Broad Network.framework compatibility projection of the interface type.
    public var type: NWInterface.InterfaceType {
        backendType.nwInterfaceType ?? .other
    }

    /// Backing Network.framework interface when this value originated from discovery.
    public var networkInterface: NWInterface? {
        nativeNetworkInterface
    }
#endif

    /// Backend-independent interface metadata for portable consumers.
    public var backendInterface: LoomNetworkInterface {
        LoomNetworkInterface(
            name: name,
            index: index,
            type: backendType
        )
    }

    /// Interface class inferred from the system name and Network.framework type.
    public var kind: LoomDiscoveredInterfaceKind {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedName.hasPrefix("anpi") {
            return .applePrivateNCM
        }
        if normalizedName.hasPrefix("awdl") {
            return .awdl
        }
        if normalizedName.hasPrefix("llw") {
            return .lowLatencyWireless
        }
        if normalizedName.hasPrefix("bridge") {
            return .bridge
        }
        if normalizedName.hasPrefix("utun") {
            return .overlay
        }
        if normalizedName.hasPrefix("pdp_ip") {
            return .cellular
        }
        if normalizedName == "lo" || normalizedName.hasPrefix("lo") {
            return .loopback
        }

        switch backendType {
        case .wifi:
            return .wifi
        case .wiredEthernet:
            return .wiredEthernet
        case .cellular:
            return .cellular
        case .loopback:
            return .loopback
        default:
            return .other
        }
    }

    /// Lower values should be attempted first for proximity-oriented connections.
    public var proximityPriority: Int? {
        switch kind {
        case .applePrivateNCM:
            0
        case .awdl:
            1
        case .lowLatencyWireless:
            2
        case .wiredEthernet:
            3
        case .bridge:
            4
        case .wifi, .cellular, .loopback, .overlay, .other:
            nil
        }
    }

    /// Whether this interface is worth trying before normal resolved-IP fallback.
    public var isProximityPreferred: Bool {
        proximityPriority != nil
    }

    /// Whether this interface represents an Apple peer-to-peer link.
    public var isPeerToPeer: Bool {
        kind == .awdl
    }

    /// Creates interface metadata without a platform networking type.
    public init(
        name: String,
        backendType: LoomNetworkInterfaceType,
        index: Int
    ) {
        self.name = name
        self.backendType = backendType
        self.index = index
#if canImport(Network)
        nativeNetworkInterface = nil
#endif
    }

#if canImport(Network)
    /// Creates interface metadata using the released Network.framework API.
    public init(
        name: String,
        type: NWInterface.InterfaceType,
        index: Int,
        networkInterface: NWInterface? = nil
    ) {
        self.name = name
        backendType = LoomNetworkInterfaceType(type)
        self.index = index
        nativeNetworkInterface = networkInterface
    }

    public init(_ interface: NWInterface) {
        self.init(
            name: interface.name,
            type: interface.type,
            index: interface.index,
            networkInterface: interface
        )
    }
#endif

    public static func == (lhs: LoomDiscoveredInterface, rhs: LoomDiscoveredInterface) -> Bool {
        lhs.name == rhs.name && lhs.index == rhs.index && lhs.backendType == rhs.backendType
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(index)
        hasher.combine(backendType)
    }
}

/// Source of a resolved Bonjour service address.
public enum LoomResolvedServiceAddressSource: String, Hashable, Sendable {
    /// Address returned by `NetService.resolve()`.
    case netService
}

/// A resolved Bonjour address with any route evidence that can be proven from
/// the address itself.
public struct LoomResolvedServiceAddress: Hashable, Sendable {
    public let backendHost: LoomNetworkHost
    public let interfaceName: String?
    public let interfaceKind: LoomDiscoveredInterfaceKind?
    public let source: LoomResolvedServiceAddressSource

    public var hasInterfaceScope: Bool {
        interfaceName != nil
    }

#if canImport(Network)
    /// Network.framework compatibility projection of the resolved host.
    public var host: NWEndpoint.Host {
        backendHost.nwHost
    }
#endif

    /// Creates a resolved service address without a platform networking type.
    public init(
        backendHost: LoomNetworkHost,
        interfaceName: String? = nil,
        interfaceKind: LoomDiscoveredInterfaceKind? = nil,
        source: LoomResolvedServiceAddressSource = .netService
    ) {
        self.backendHost = backendHost
        self.interfaceName = interfaceName
        self.interfaceKind = interfaceKind
        self.source = source
    }

#if canImport(Network)
    /// Creates a resolved service address using the released Network.framework API.
    public init(
        host: NWEndpoint.Host,
        interfaceName: String? = nil,
        interfaceKind: LoomDiscoveredInterfaceKind? = nil,
        source: LoomResolvedServiceAddressSource = .netService
    ) {
        self.init(
            backendHost: LoomNetworkHost(host),
            interfaceName: interfaceName,
            interfaceKind: interfaceKind,
            source: source
        )
    }
#endif
}

/// Represents a discovered peer on the network.
public struct LoomPeer: Identifiable, Hashable, Sendable {
    /// Unique identifier for this peer.
    public let id: LoomPeerID

    /// Display name advertised by the peer.
    public let name: String

    /// Broad Apple-platform device classification for the peer.
    public let deviceType: DeviceType

    /// Backend-independent network endpoint used to connect to the peer.
    public let backendEndpoint: LoomNetworkEndpoint

    /// Discovery advertisement published by the peer.
    public let advertisement: LoomPeerAdvertisement

    /// IP addresses resolved via Bonjour service resolution.
    ///
    /// When a peer is discovered via mDNS, these are the actual IP addresses
    /// returned by `NetService.resolve()`. IPv4 addresses appear first.
    /// Consumers should prefer these over re-resolving the advertised hostname
    /// to avoid platform-specific mDNS resolution failures (e.g. iOS).
    public let backendResolvedAddresses: [LoomNetworkHost]

    /// Resolved Bonjour service addresses with any interface binding that was
    /// present in the resolved socket address.
    public let resolvedServiceAddresses: [LoomResolvedServiceAddress]

    /// Interfaces on which this peer was discovered.
    public let discoveredInterfaces: [LoomDiscoveredInterface]

#if canImport(Network)
    private let nativeEndpoint: NWEndpoint?

    /// Network.framework compatibility projection of the connection endpoint.
    public var endpoint: NWEndpoint {
        if let nativeEndpoint {
            return nativeEndpoint
        }
        switch backendEndpoint {
        case let .hostPort(host, port):
            return .hostPort(
                host: host.nwHost,
                port: NWEndpoint.Port(rawValue: port) ?? .any
            )
        case let .service(name, type, domain, _):
            return .service(name: name, type: type, domain: domain, interface: nil)
        case let .opaque(description):
            preconditionFailure("Opaque backend endpoint cannot be projected to Network.framework: \(description)")
        }
    }

    /// Network.framework compatibility projection of resolved service hosts.
    public var resolvedAddresses: [NWEndpoint.Host] {
        backendResolvedAddresses.map(\.nwHost)
    }
#endif

    /// Convenience access to the host device backing this peer.
    public var deviceID: UUID {
        id.deviceID
    }

    /// Optional app identifier when the peer was synthesized from a shared host catalog.
    public var appID: String? {
        id.appID
    }

    /// Creates a peer without exposing a platform networking type.
    public init(
        id: LoomPeerID,
        name: String,
        deviceType: DeviceType,
        backendEndpoint: LoomNetworkEndpoint,
        advertisement: LoomPeerAdvertisement,
        backendResolvedAddresses: [LoomNetworkHost] = [],
        resolvedServiceAddresses: [LoomResolvedServiceAddress] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.backendEndpoint = backendEndpoint
        self.advertisement = advertisement
        self.backendResolvedAddresses = backendResolvedAddresses
        self.resolvedServiceAddresses = resolvedServiceAddresses.isEmpty
            ? backendResolvedAddresses.map { LoomResolvedServiceAddress(backendHost: $0) }
            : resolvedServiceAddresses
        self.discoveredInterfaces = discoveredInterfaces
#if canImport(Network)
        nativeEndpoint = nil
#endif
    }

#if canImport(Network)
    /// Creates a peer using the released Network.framework endpoint API.
    public init(
        id: LoomPeerID,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        advertisement: LoomPeerAdvertisement,
        resolvedAddresses: [NWEndpoint.Host] = [],
        resolvedServiceAddresses: [LoomResolvedServiceAddress] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        backendEndpoint = LoomNetworkEndpoint(endpoint) ?? .opaque(description: String(describing: endpoint))
        self.advertisement = advertisement
        backendResolvedAddresses = resolvedAddresses.map(LoomNetworkHost.init)
        self.resolvedServiceAddresses = resolvedServiceAddresses.isEmpty
            ? resolvedAddresses.map { LoomResolvedServiceAddress(host: $0) }
            : resolvedServiceAddresses
        self.discoveredInterfaces = discoveredInterfaces
        nativeEndpoint = endpoint
    }

    public init(
        id: UUID,
        appID: String? = nil,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        advertisement: LoomPeerAdvertisement,
        resolvedAddresses: [NWEndpoint.Host] = [],
        resolvedServiceAddresses: [LoomResolvedServiceAddress] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
    ) {
        self.init(
            id: LoomPeerID(deviceID: id, appID: appID),
            name: name,
            deviceType: deviceType,
            endpoint: endpoint,
            advertisement: advertisement,
            resolvedAddresses: resolvedAddresses,
            resolvedServiceAddresses: resolvedServiceAddresses,
            discoveredInterfaces: discoveredInterfaces
        )
    }

    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        advertisement: LoomPeerAdvertisement,
        resolvedAddresses: [NWEndpoint.Host] = [],
        resolvedServiceAddresses: [LoomResolvedServiceAddress] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
    ) {
        self.init(
            id: LoomPeerID(deviceID: id),
            name: name,
            deviceType: deviceType,
            endpoint: endpoint,
            advertisement: advertisement,
            resolvedAddresses: resolvedAddresses,
            resolvedServiceAddresses: resolvedServiceAddresses,
            discoveredInterfaces: discoveredInterfaces
        )
    }
#endif

    /// Creates a peer identifier from a device and optional application ID
    /// without exposing a platform networking type.
    public init(
        id: UUID,
        appID: String? = nil,
        name: String,
        deviceType: DeviceType,
        backendEndpoint: LoomNetworkEndpoint,
        advertisement: LoomPeerAdvertisement,
        backendResolvedAddresses: [LoomNetworkHost] = [],
        resolvedServiceAddresses: [LoomResolvedServiceAddress] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
    ) {
        self.init(
            id: LoomPeerID(deviceID: id, appID: appID),
            name: name,
            deviceType: deviceType,
            backendEndpoint: backendEndpoint,
            advertisement: advertisement,
            backendResolvedAddresses: backendResolvedAddresses,
            resolvedServiceAddresses: resolvedServiceAddresses,
            discoveredInterfaces: discoveredInterfaces
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: LoomPeer, rhs: LoomPeer) -> Bool {
        lhs.id == rhs.id
    }
}

/// Direct transport advertisement published by a Loom peer.
public struct LoomDirectTransportAdvertisement: Codable, Hashable, Sendable {
    /// Direct transport protocol used to accept Loom sessions.
    public let transportKind: LoomTransportKind
    /// Listening port for the transport.
    public let port: UInt16
    /// Broad local-network path hint associated with the transport, when known.
    public let pathKind: LoomDirectPathKind?

    public init(
        transportKind: LoomTransportKind,
        port: UInt16,
        pathKind: LoomDirectPathKind? = nil
    ) {
        self.transportKind = transportKind
        self.port = port
        self.pathKind = pathKind
    }
}

/// Device type enumeration.
///
/// Unrecognized encoded values decode as ``unknown`` so peers can add device
/// families without making older decoders reject an entire containing payload.
public enum DeviceType: String, Codable, Sendable {
    case mac
    case iPad
    case iPhone
    case vision
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = DeviceType(rawValue: rawValue) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String {
        switch self {
        case .mac: "Mac"
        case .iPad: "iPad"
        case .iPhone: "iPhone"
        case .vision: "Apple Vision Pro"
        case .unknown: "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .mac: "desktopcomputer"
        case .iPad: "ipad"
        case .iPhone: "iphone"
        case .vision: "visionpro"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Original device-type spelling carried on the wire. Unknown values project to
/// ``DeviceType/unknown`` without losing the bytes covered by handshake signatures.
package struct LoomDeviceTypeWireValue: Sendable, Hashable {
    package let rawValue: String

    package init(_ deviceType: DeviceType) {
        rawValue = deviceType.rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package var deviceType: DeviceType {
        DeviceType(rawValue: rawValue) ?? .unknown
    }

    package static func == (lhs: LoomDeviceTypeWireValue, rhs: LoomDeviceTypeWireValue) -> Bool {
        lhs.deviceType == rhs.deviceType
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(deviceType)
    }
}

/// Generic peer advertisement published over discovery and cloud registries.
///
/// App-specific semantics should live in the namespaced `metadata` dictionary
/// rather than in Loom-owned fields.
public struct LoomPeerAdvertisement: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let deviceID: UUID?
    public let identityKeyID: String?
    public let deviceType: DeviceType?
    public let modelIdentifier: String?
    public let iconName: String?
    public let machineFamily: String?
    /// The mDNS hostname of the advertising peer (e.g., `"Ethans-Mac-Studio.local"`).
    public let hostName: String?
    public let directTransports: [LoomDirectTransportAdvertisement]
    public let metadata: [String: String]
    private let deviceTypeWireValue: LoomDeviceTypeWireValue?

    public init(
        protocolVersion: Int = Int(Loom.protocolVersion),
        deviceID: UUID? = nil,
        identityKeyID: String? = nil,
        deviceType: DeviceType? = nil,
        modelIdentifier: String? = nil,
        iconName: String? = nil,
        machineFamily: String? = nil,
        hostName: String? = nil,
        directTransports: [LoomDirectTransportAdvertisement] = [],
        metadata: [String: String] = [:]
    ) {
        self.init(
            protocolVersion: protocolVersion,
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceTypeWireValue: deviceType.map(LoomDeviceTypeWireValue.init),
            modelIdentifier: modelIdentifier,
            iconName: iconName,
            machineFamily: machineFamily,
            hostName: hostName,
            directTransports: directTransports,
            metadata: metadata
        )
    }

    private init(
        protocolVersion: Int,
        deviceID: UUID?,
        identityKeyID: String?,
        deviceTypeWireValue: LoomDeviceTypeWireValue?,
        modelIdentifier: String?,
        iconName: String?,
        machineFamily: String?,
        hostName: String?,
        directTransports: [LoomDirectTransportAdvertisement],
        metadata: [String: String]
    ) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.identityKeyID = identityKeyID
        self.deviceTypeWireValue = deviceTypeWireValue
        deviceType = deviceTypeWireValue?.deviceType
        self.modelIdentifier = modelIdentifier
        self.iconName = iconName
        self.machineFamily = machineFamily
        self.hostName = hostName
        self.directTransports = directTransports
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case deviceID
        case identityKeyID
        case deviceType
        case modelIdentifier
        case iconName
        case machineFamily
        case hostName
        case directTransports
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceTypeRawValue = try container.decodeIfPresent(String.self, forKey: .deviceType)
        self.init(
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
            deviceID: try container.decodeIfPresent(UUID.self, forKey: .deviceID),
            identityKeyID: try container.decodeIfPresent(String.self, forKey: .identityKeyID),
            deviceTypeWireValue: deviceTypeRawValue.map(LoomDeviceTypeWireValue.init(rawValue:)),
            modelIdentifier: try container.decodeIfPresent(String.self, forKey: .modelIdentifier),
            iconName: try container.decodeIfPresent(String.self, forKey: .iconName),
            machineFamily: try container.decodeIfPresent(String.self, forKey: .machineFamily),
            hostName: try container.decodeIfPresent(String.self, forKey: .hostName),
            directTransports: try container.decode(
                [LoomDirectTransportAdvertisement].self,
                forKey: .directTransports
            ),
            metadata: try container.decode([String: String].self, forKey: .metadata)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(identityKeyID, forKey: .identityKeyID)
        try container.encodeIfPresent(deviceTypeWireValue?.rawValue, forKey: .deviceType)
        try container.encodeIfPresent(modelIdentifier, forKey: .modelIdentifier)
        try container.encodeIfPresent(iconName, forKey: .iconName)
        try container.encodeIfPresent(machineFamily, forKey: .machineFamily)
        try container.encodeIfPresent(hostName, forKey: .hostName)
        try container.encode(directTransports, forKey: .directTransports)
        try container.encode(metadata, forKey: .metadata)
    }

    /// Encode to a Bonjour TXT record dictionary.
    public func toTXTRecord() -> [String: String] {
        var record: [String: String] = [
            Self.protocolVersionKey: String(protocolVersion),
        ]

        if let deviceID {
            record[Self.deviceIDKey] = deviceID.uuidString
        }
        if let identityKeyID {
            record[Self.identityKeyIDKey] = identityKeyID
        }
        if let deviceTypeWireValue {
            record[Self.deviceTypeKey] = deviceTypeWireValue.rawValue
        }
        if let modelIdentifier {
            record[Self.modelIdentifierKey] = modelIdentifier
        }
        if let iconName {
            record[Self.iconNameKey] = iconName
        }
        if let machineFamily {
            record[Self.machineFamilyKey] = machineFamily
        }
        if let hostName {
            record[Self.hostNameKey] = hostName
        }
        for transport in directTransports {
            record[Self.directTransportKey(for: transport.transportKind)] = String(transport.port)
            if let pathKind = transport.pathKind {
                record[Self.directTransportPathKey(for: transport.transportKind)] = pathKind.rawValue
            }
        }

        for (key, value) in metadata where Self.reservedKeys.contains(key) == false {
            record[key] = value
        }

        return record
    }

    /// Decode from a Bonjour TXT record dictionary.
    public static func from(txtRecord: [String: String]) -> LoomPeerAdvertisement {
        var metadata: [String: String] = [:]
        for (key, value) in txtRecord where reservedKeys.contains(key) == false {
            guard let sanitizedValue = sanitizedTXTValue(value) else { continue }
            metadata[key] = sanitizedValue
        }

        let deviceTypeWireValue = sanitizedTXTValue(txtRecord[deviceTypeKey])
            .map(LoomDeviceTypeWireValue.init(rawValue:))
        let directTransports: [LoomDirectTransportAdvertisement] = LoomTransportKind.allCases.compactMap { transportKind in
            guard let rawPort = sanitizedTXTValue(txtRecord[directTransportKey(for: transportKind)]),
                  let port = UInt16(rawPort),
                  port > 0 else {
                return nil
            }
            let pathKind = sanitizedTXTValue(txtRecord[directTransportPathKey(for: transportKind)])
                .flatMap(LoomDirectPathKind.init(rawValue:))
            return LoomDirectTransportAdvertisement(
                transportKind: transportKind,
                port: port,
                pathKind: pathKind
            )
        }

        return LoomPeerAdvertisement(
            protocolVersion: Int(sanitizedTXTValue(txtRecord[protocolVersionKey]) ?? "1") ?? 1,
            deviceID: sanitizedTXTValue(txtRecord[deviceIDKey]).flatMap(UUID.init(uuidString:)),
            identityKeyID: sanitizedTXTValue(txtRecord[identityKeyIDKey]),
            deviceTypeWireValue: deviceTypeWireValue,
            modelIdentifier: sanitizedTXTValue(txtRecord[modelIdentifierKey]),
            iconName: sanitizedTXTValue(txtRecord[iconNameKey]),
            machineFamily: sanitizedTXTValue(txtRecord[machineFamilyKey]),
            hostName: sanitizedTXTValue(txtRecord[hostNameKey]),
            directTransports: directTransports,
            metadata: metadata
        )
    }

    private static let protocolVersionKey = "proto"
    private static let deviceIDKey = "did"
    private static let identityKeyIDKey = "ikid"
    private static let deviceTypeKey = "dt"
    private static let modelIdentifierKey = "model"
    private static let iconNameKey = "icon"
    private static let machineFamilyKey = "family"
    private static let hostNameKey = "hn"
    private static let tcpPortKey = "tcp"
    private static let tcpPathKey = "tcp-path"
    private static let quicPortKey = "quic"
    private static let quicPathKey = "quic-path"
    private static let udpPortKey = "udp"
    private static let udpPathKey = "udp-path"
    private static let reservedKeys: Set<String> = [
        protocolVersionKey,
        deviceIDKey,
        identityKeyIDKey,
        deviceTypeKey,
        modelIdentifierKey,
        iconNameKey,
        machineFamilyKey,
        hostNameKey,
        tcpPortKey,
        tcpPathKey,
        quicPortKey,
        quicPathKey,
        udpPortKey,
        udpPathKey,
    ]

    private static func directTransportKey(for transportKind: LoomTransportKind) -> String {
        switch transportKind {
        case .tcp:
            tcpPortKey
        case .quic:
            quicPortKey
        case .udp:
            udpPortKey
        }
    }

    private static func directTransportPathKey(for transportKind: LoomTransportKind) -> String {
        switch transportKind {
        case .tcp:
            tcpPathKey
        case .quic:
            quicPathKey
        case .udp:
            udpPathKey
        }
    }

    private static func sanitizedTXTValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nulIndex = cleaned.firstIndex(of: "\u{0}") {
            cleaned = String(cleaned[..<nulIndex])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
