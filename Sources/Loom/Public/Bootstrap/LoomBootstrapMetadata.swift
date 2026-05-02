//
//  LoomBootstrapMetadata.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Bootstrap metadata shared between peer publication and recovery logic.
//

import Foundation

/// Origin of a bootstrap endpoint.
public enum LoomBootstrapEndpointSource: String, Codable, CaseIterable, Sendable {
    /// Explicit endpoint entered in peer settings.
    case user
    /// Endpoint inferred from peer network interfaces.
    case auto
    /// Endpoint remembered from a previous successful bootstrap.
    case lastSeen
}

/// Network endpoint used for bootstrap recovery.
public struct LoomBootstrapEndpoint: Codable, Hashable, Sendable {
    /// Hostname or IP address.
    public let host: String
    /// TCP port used for SSH or control bootstrap.
    public let port: UInt16
    /// Source of the endpoint.
    public let source: LoomBootstrapEndpointSource

    /// Creates a bootstrap endpoint candidate.
    ///
    /// - Parameters:
    ///   - host: IP address or host name reachable by the caller.
    ///   - port: Port used for SSH or daemon control, depending on context.
    ///   - source: Source that produced the endpoint (`user`, `auto`, or `lastSeen`).
    public init(
        host: String,
        port: UInt16,
        source: LoomBootstrapEndpointSource
    ) {
        self.host = host
        self.port = port
        self.source = source
    }
}

/// Wake-on-LAN metadata published by a peer.
public struct LoomWakeOnLANInfo: Codable, Hashable, Sendable {
    /// Target NIC MAC address used to build magic packets.
    public let macAddress: String
    /// Broadcast targets where magic packets should be sent.
    public let broadcastAddresses: [String]

    /// Creates Wake-on-LAN metadata.
    ///
    /// - Parameters:
    ///   - macAddress: Target NIC MAC address.
    ///   - broadcastAddresses: UDP broadcast destinations where packets are sent.
    ///
    /// - Note: Broadcast addresses are typically subnet broadcasts such as `192.168.1.255`.
    public init(macAddress: String, broadcastAddresses: [String]) {
        self.macAddress = macAddress
        self.broadcastAddresses = broadcastAddresses
    }
}

/// Bootstrap capability metadata stored with peer records.
public struct LoomBootstrapMetadata: Codable, Hashable, Sendable {
    /// Metadata version for forward-compatible decoding.
    public static let currentVersion = 6

    /// Metadata schema version.
    public let version: Int
    /// Whether the peer opted into bootstrap recovery features.
    public let enabled: Bool
    /// Whether the peer exposes a pre-login daemon that can accept unlock requests.
    public let supportsPreloginDaemon: Bool
    /// SSH/bootstrap endpoints published by the peer.
    public let endpoints: [LoomBootstrapEndpoint]
    /// Preferred SSH port for SSH-based bootstrap credential submission.
    public let sshPort: UInt16?
    /// Optional bootstrap control port for daemon handoff.
    public let controlPort: UInt16?
    /// Shared secret used to encrypt pre-login daemon control requests.
    public let controlAuthSecret: String?
    /// Pinned SHA256 fingerprints for SSH host-key validation.
    public let sshHostKeyFingerprints: [String]
    /// Wake-on-LAN metadata when available.
    public let wakeOnLAN: LoomWakeOnLANInfo?

    /// Creates peer bootstrap capability metadata.
    ///
    /// - Parameters:
    ///   - version: Metadata version. Keep default unless you are migrating schema.
    ///   - enabled: Whether bootstrap recovery is enabled by user policy.
    ///   - supportsPreloginDaemon: Whether a pre-login daemon is available for unlock handoff.
    ///   - endpoints: Candidate endpoints for bootstrap connection attempts.
    ///   - sshPort: Preferred SSH port.
    ///   - controlPort: Preferred daemon control port.
    ///   - controlAuthSecret: Shared secret used to encrypt daemon control requests.
    ///   - sshHostKeyFingerprints: Pinned SHA256 host-key fingerprints accepted for SSH bootstrap.
    ///   - wakeOnLAN: Optional Wake-on-LAN payload data.
    ///
    /// Example:
    /// ```swift
    /// let metadata = LoomBootstrapMetadata(
    ///     enabled: true,
    ///     supportsPreloginDaemon: true,
    ///     endpoints: [.init(host: "192.168.1.10", port: 22, source: .auto)],
    ///     sshPort: 22,
    ///     controlPort: 9849,
    ///     sshHostKeyFingerprints: ["SHA256:..."],
    ///     wakeOnLAN: .init(macAddress: "AA:BB:CC:DD:EE:FF", broadcastAddresses: ["192.168.1.255"])
    /// )
    /// ```
    public init(
        version: Int = LoomBootstrapMetadata.currentVersion,
        enabled: Bool,
        supportsPreloginDaemon: Bool,
        endpoints: [LoomBootstrapEndpoint],
        sshPort: UInt16?,
        controlPort: UInt16?,
        controlAuthSecret: String? = nil,
        sshHostKeyFingerprints: [String] = [],
        wakeOnLAN: LoomWakeOnLANInfo?
    ) {
        self.version = version
        self.enabled = enabled
        self.supportsPreloginDaemon = supportsPreloginDaemon
        self.endpoints = endpoints
        self.sshPort = sshPort
        self.controlPort = controlPort
        self.controlAuthSecret = controlAuthSecret
        self.sshHostKeyFingerprints = sshHostKeyFingerprints
        self.wakeOnLAN = wakeOnLAN
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case enabled
        case supportsPreloginDaemon
        case endpoints
        case sshPort
        case controlPort
        case controlAuthSecret
        case sshHostKeyFingerprints
        case wakeOnLAN
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        enabled = try container.decode(Bool.self, forKey: .enabled)
        supportsPreloginDaemon = try container.decode(Bool.self, forKey: .supportsPreloginDaemon)
        endpoints = try container.decode([LoomBootstrapEndpoint].self, forKey: .endpoints)
        sshPort = try container.decodeIfPresent(UInt16.self, forKey: .sshPort)
        controlPort = try container.decodeIfPresent(UInt16.self, forKey: .controlPort)
        controlAuthSecret = try container.decodeIfPresent(String.self, forKey: .controlAuthSecret)
        sshHostKeyFingerprints = try container.decodeIfPresent(
            [String].self,
            forKey: .sshHostKeyFingerprints
        ) ?? []
        wakeOnLAN = try container.decodeIfPresent(LoomWakeOnLANInfo.self, forKey: .wakeOnLAN)
    }
}
