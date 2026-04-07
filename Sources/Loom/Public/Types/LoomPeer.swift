//
//  LoomPeer.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network

/// Represents a discovered peer on the network.
public struct LoomPeer: Identifiable, Hashable, Sendable {
    /// Unique identifier for this peer.
    public let id: LoomPeerID

    /// Display name advertised by the peer.
    public let name: String

    /// Broad Apple-platform device classification for the peer.
    public let deviceType: DeviceType

    /// Network endpoint used to connect to the peer.
    public let endpoint: NWEndpoint

    /// Discovery advertisement published by the peer.
    public let advertisement: LoomPeerAdvertisement

    /// IP addresses resolved via Bonjour service resolution.
    ///
    /// When a peer is discovered via mDNS, these are the actual IP addresses
    /// returned by `NetService.resolve()`. IPv4 addresses appear first.
    /// Consumers should prefer these over re-resolving the advertised hostname
    /// to avoid platform-specific mDNS resolution failures (e.g. iOS).
    public let resolvedAddresses: [NWEndpoint.Host]

    /// Convenience access to the host device backing this peer.
    public var deviceID: UUID {
        id.deviceID
    }

    /// Optional app identifier when the peer was synthesized from a shared host catalog.
    public var appID: String? {
        id.appID
    }

    public init(
        id: LoomPeerID,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        advertisement: LoomPeerAdvertisement,
        resolvedAddresses: [NWEndpoint.Host] = []
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.endpoint = endpoint
        self.advertisement = advertisement
        self.resolvedAddresses = resolvedAddresses
    }

    public init(
        id: UUID,
        appID: String? = nil,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        advertisement: LoomPeerAdvertisement,
        resolvedAddresses: [NWEndpoint.Host] = []
    ) {
        self.init(
            id: LoomPeerID(deviceID: id, appID: appID),
            name: name,
            deviceType: deviceType,
            endpoint: endpoint,
            advertisement: advertisement,
            resolvedAddresses: resolvedAddresses
        )
    }

    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        advertisement: LoomPeerAdvertisement,
        resolvedAddresses: [NWEndpoint.Host] = []
    ) {
        self.init(
            id: LoomPeerID(deviceID: id),
            name: name,
            deviceType: deviceType,
            endpoint: endpoint,
            advertisement: advertisement,
            resolvedAddresses: resolvedAddresses
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
public enum DeviceType: String, Codable, Sendable {
    case mac
    case iPad
    case iPhone
    case vision
    case unknown

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
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.identityKeyID = identityKeyID
        self.deviceType = deviceType
        self.modelIdentifier = modelIdentifier
        self.iconName = iconName
        self.machineFamily = machineFamily
        self.hostName = hostName
        self.directTransports = directTransports
        self.metadata = metadata
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
        if let deviceType {
            record[Self.deviceTypeKey] = deviceType.rawValue
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

        let deviceType = sanitizedTXTValue(txtRecord[deviceTypeKey]).flatMap(DeviceType.init(rawValue:))
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
            deviceType: deviceType,
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
