//
//  LoomShellIdentity.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Loom

/// App-owned local identity information used to construct shell session hello requests and advertisements.
public struct LoomShellIdentity: Sendable, Equatable {
    public let deviceID: UUID
    public let deviceName: String
    public let deviceType: DeviceType
    public let iCloudUserID: String?
    public let additionalAdvertisementMetadata: [String: String]
    public let additionalSupportedFeatures: [String]

    public init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        iCloudUserID: String? = nil,
        additionalAdvertisementMetadata: [String: String] = [:],
        additionalSupportedFeatures: [String] = []
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.iCloudUserID = iCloudUserID
        self.additionalAdvertisementMetadata = additionalAdvertisementMetadata
        self.additionalSupportedFeatures = additionalSupportedFeatures
    }

    public func makeAdvertisement(
        identityKeyID: String? = nil,
        capabilities: LoomShellPeerCapabilities? = nil
    ) throws -> LoomPeerAdvertisement {
        try deviceProfile.makeAdvertisement(
            identityKeyID: identityKeyID
        ) { metadata in
            try LoomShellAdvertisementCodec.addingCapabilities(capabilities, to: metadata)
        }
    }

    public func makeHelloRequest(
        identityKeyID: String? = nil,
        capabilities: LoomShellPeerCapabilities? = nil
    ) throws -> LoomSessionHelloRequest {
        let advertisement = try deviceProfile.makeAdvertisement(
            identityKeyID: identityKeyID
        ) { metadata in
            try LoomShellAdvertisementCodec.addingCapabilities(capabilities, to: metadata)
        }
        return LoomSessionHelloRequest(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: deviceType,
            advertisement: advertisement,
            supportedFeatures: supportedFeatures(for: capabilities),
            iCloudUserID: iCloudUserID
        )
    }

    private func supportedFeatures(for capabilities: LoomShellPeerCapabilities?) -> [String] {
        var features = Set(deviceProfile.supportedFeatures)
        features.insert(LoomShellProtocol.nativeFeature)
        if capabilities?.supportsOpenSSHFallback == true {
            features.insert(LoomShellProtocol.openSSHFallbackFeature)
        }
        return features.sorted()
    }

    private var deviceProfile: LoomDeviceProfile {
        LoomDeviceProfile(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: deviceType,
            iCloudUserID: iCloudUserID,
            additionalAdvertisementMetadata: additionalAdvertisementMetadata,
            additionalSupportedFeatures: additionalSupportedFeatures
        )
    }
}

/// Capabilities published by a LoomShell host in discovery metadata.
public struct LoomShellPeerCapabilities: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let supportsLoomNativeShell: Bool
    public let supportsOpenSSHFallback: Bool
    public let supportedDirectTransports: [LoomTransportKind]
    public let bootstrapMetadata: LoomBootstrapMetadata?

    public init(
        version: Int = LoomShellPeerCapabilities.currentVersion,
        supportsLoomNativeShell: Bool,
        supportsOpenSSHFallback: Bool,
        supportedDirectTransports: [LoomTransportKind],
        bootstrapMetadata: LoomBootstrapMetadata? = nil
    ) {
        self.version = version
        self.supportsLoomNativeShell = supportsLoomNativeShell
        self.supportsOpenSSHFallback = supportsOpenSSHFallback
        self.supportedDirectTransports = Array(Set(supportedDirectTransports)).sorted { lhs, rhs in
            lhs.rawValue < rhs.rawValue
        }
        self.bootstrapMetadata = bootstrapMetadata
    }

    public func supportsDirectTransport(_ transport: LoomTransportKind) -> Bool {
        supportedDirectTransports.contains(transport)
    }

    public var supportsAnyShellPath: Bool {
        supportsLoomNativeShell || supportsOpenSSHFallback
    }
}

/// Discovered peer plus parsed shell-specific capabilities.
public struct LoomShellDiscoveredPeer: Sendable, Hashable {
    public let peer: LoomPeer
    public let capabilities: LoomShellPeerCapabilities?

    public init(peer: LoomPeer) {
        self.peer = peer
        capabilities = LoomShellAdvertisementCodec.capabilities(from: peer.advertisement)
    }

    public init(peer: LoomPeer, capabilities: LoomShellPeerCapabilities?) {
        self.peer = peer
        self.capabilities = capabilities
    }

    public var bootstrapMetadata: LoomBootstrapMetadata? {
        capabilities?.bootstrapMetadata
    }

    public var supportsLoomNativeShell: Bool {
        capabilities?.supportsLoomNativeShell ?? false
    }

    public var supportsOpenSSHFallback: Bool {
        capabilities?.supportsOpenSSHFallback ?? false
    }

    public var supportsAnyShellPath: Bool {
        capabilities?.supportsAnyShellPath ?? false
    }
}

/// Helpers for encoding shell capabilities into Loom advertisements.
public enum LoomShellAdvertisementCodec {
    public static let capabilitiesMetadataKey = "loom.shell.capabilities"

    public static func addingCapabilities(
        _ capabilities: LoomShellPeerCapabilities?,
        to metadata: [String: String]
    ) throws -> [String: String] {
        var metadata = metadata
        if let capabilities {
            let encoded = try JSONEncoder().encode(capabilities)
            metadata[capabilitiesMetadataKey] = encoded.base64EncodedString()
        } else {
            metadata.removeValue(forKey: capabilitiesMetadataKey)
        }
        return metadata
    }

    public static func capabilities(from advertisement: LoomPeerAdvertisement) -> LoomShellPeerCapabilities? {
        guard let encoded = advertisement.metadata[capabilitiesMetadataKey],
              let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return try? JSONDecoder().decode(LoomShellPeerCapabilities.self, from: data)
    }
}
