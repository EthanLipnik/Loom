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
    public let id: UUID

    /// Display name advertised by the peer.
    public let name: String

    /// Broad Apple-platform device classification for the peer.
    public let deviceType: DeviceType

    /// Network endpoint used to connect to the peer.
    public let endpoint: NWEndpoint

    /// Discovery advertisement published by the peer.
    public let advertisement: LoomPeerAdvertisement

    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        advertisement: LoomPeerAdvertisement
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.endpoint = endpoint
        self.advertisement = advertisement
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: LoomPeer, rhs: LoomPeer) -> Bool {
        lhs.id == rhs.id
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
        case .vision: "Apple Vision"
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
    public let metadata: [String: String]

    public init(
        protocolVersion: Int = Int(Loom.protocolVersion),
        deviceID: UUID? = nil,
        identityKeyID: String? = nil,
        deviceType: DeviceType? = nil,
        modelIdentifier: String? = nil,
        iconName: String? = nil,
        machineFamily: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.identityKeyID = identityKeyID
        self.deviceType = deviceType
        self.modelIdentifier = modelIdentifier
        self.iconName = iconName
        self.machineFamily = machineFamily
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

        return LoomPeerAdvertisement(
            protocolVersion: Int(sanitizedTXTValue(txtRecord[protocolVersionKey]) ?? "1") ?? 1,
            deviceID: sanitizedTXTValue(txtRecord[deviceIDKey]).flatMap(UUID.init(uuidString:)),
            identityKeyID: sanitizedTXTValue(txtRecord[identityKeyIDKey]),
            deviceType: deviceType,
            modelIdentifier: sanitizedTXTValue(txtRecord[modelIdentifierKey]),
            iconName: sanitizedTXTValue(txtRecord[iconNameKey]),
            machineFamily: sanitizedTXTValue(txtRecord[machineFamilyKey]),
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
    private static let reservedKeys: Set<String> = [
        protocolVersionKey,
        deviceIDKey,
        identityKeyIDKey,
        deviceTypeKey,
        modelIdentifierKey,
        iconNameKey,
        machineFamilyKey,
    ]

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
