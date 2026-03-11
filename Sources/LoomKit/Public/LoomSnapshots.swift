//
//  LoomSnapshots.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

import Foundation
import Loom

/// Lightweight error snapshot surfaced through ``LoomContext/lastError``.
public struct LoomKitError: LocalizedError, Sendable, Equatable {
    /// Human-readable description suitable for UI presentation or logs.
    public let message: String

    /// Creates a LoomKit error wrapper with a stable user-facing message.
    public init(message: String) {
        self.message = message
    }

    /// Localized error description mirroring ``message``.
    public var errorDescription: String? {
        message
    }
}

/// Source used to populate a unified LoomKit peer snapshot.
public enum LoomPeerSource: String, Codable, CaseIterable, Hashable, Sendable {
    /// Nearby peer discovered over Bonjour or direct local advertising.
    case nearby
    /// Peer resolved through the overlay-directory off-LAN probe path.
    case overlay
    /// Peer record published by the current iCloud account.
    case cloudKitOwn
    /// Peer record visible through an accepted CloudKit share.
    case cloudKitShared
    /// Relay-backed remote host currently reachable by session ID.
    case relay
}

/// UI-friendly peer snapshot exposed by ``LoomQuery`` and ``LoomContext``.
public struct LoomPeerSnapshot: Identifiable, Hashable, Sendable {
    /// Stable logical peer identifier.
    public let id: LoomPeerID
    /// Display name shown in peer pickers and status views.
    public let name: String
    /// Coarse-grained device family for the peer.
    public let deviceType: DeviceType
    /// Source channels currently contributing to this merged peer view.
    public let sources: [LoomPeerSource]
    /// Indicates whether the peer is currently reachable nearby.
    public let isNearby: Bool
    /// Indicates whether the peer is visible through a shared CloudKit graph.
    public let isShared: Bool
    /// Indicates whether the peer currently publishes relay-backed remote access.
    public let remoteAccessEnabled: Bool
    /// Relay session identifier published for remote joins, when available.
    public let relaySessionID: String?
    /// Decoded Loom advertisement for feature and identity inspection.
    public let advertisement: LoomPeerAdvertisement
    /// Optional bootstrap metadata resolved from CloudKit or local advertisement state.
    public let bootstrapMetadata: LoomBootstrapMetadata?
    /// Timestamp of the most recent observation for this peer.
    public let lastSeen: Date

    /// Convenience access to the host device backing this peer.
    public var deviceID: UUID {
        id.deviceID
    }

    /// Optional app identifier when the peer was synthesized from a shared host.
    public var appID: String? {
        id.appID
    }

    /// Creates a UI snapshot for one logical peer merged across nearby and CloudKit sources.
    public init(
        id: LoomPeerID,
        name: String,
        deviceType: DeviceType,
        sources: [LoomPeerSource],
        isNearby: Bool,
        isShared: Bool,
        remoteAccessEnabled: Bool,
        relaySessionID: String?,
        advertisement: LoomPeerAdvertisement,
        bootstrapMetadata: LoomBootstrapMetadata?,
        lastSeen: Date
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.sources = Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
        self.isNearby = isNearby
        self.isShared = isShared
        self.remoteAccessEnabled = remoteAccessEnabled
        self.relaySessionID = relaySessionID
        self.advertisement = advertisement
        self.bootstrapMetadata = bootstrapMetadata
        self.lastSeen = lastSeen
    }

    public init(
        id: UUID,
        appID: String? = nil,
        name: String,
        deviceType: DeviceType,
        sources: [LoomPeerSource],
        isNearby: Bool,
        isShared: Bool,
        remoteAccessEnabled: Bool,
        relaySessionID: String?,
        advertisement: LoomPeerAdvertisement,
        bootstrapMetadata: LoomBootstrapMetadata?,
        lastSeen: Date
    ) {
        self.init(
            id: LoomPeerID(deviceID: id, appID: appID),
            name: name,
            deviceType: deviceType,
            sources: sources,
            isNearby: isNearby,
            isShared: isShared,
            remoteAccessEnabled: remoteAccessEnabled,
            relaySessionID: relaySessionID,
            advertisement: advertisement,
            bootstrapMetadata: bootstrapMetadata,
            lastSeen: lastSeen
        )
    }
}

/// UI-friendly active-connection snapshot exposed by ``LoomQuery`` and ``LoomContext``.
public struct LoomConnectionSnapshot: Identifiable, Hashable, Sendable {
    /// High-level connection lifecycle state used by SwiftUI views.
    public enum State: String, Codable, Sendable {
        /// A connection attempt has started and is still negotiating.
        case connecting
        /// The authenticated session is open and usable.
        case connected
        /// The connection is tearing down locally.
        case disconnecting
        /// The connection closed cleanly or was cancelled.
        case disconnected
        /// The connection failed and surfaced an error.
        case failed
    }

    /// Stable LoomKit connection identifier.
    public let id: UUID
    /// Peer identifier associated with the connection.
    public let peerID: LoomPeerID
    /// Peer name captured when the connection snapshot was produced.
    public let peerName: String
    /// High-level lifecycle state for UI presentation.
    public let state: State
    /// Transport kind that backed the authenticated session.
    public let transportKind: LoomTransportKind
    /// Timestamp for when the connection record entered the store.
    public let connectedAt: Date
    /// Last disconnection or failure message recorded for the connection.
    public let lastError: String?

    /// Creates a connection snapshot suitable for `@LoomQuery` and list rendering.
    public init(
        id: UUID,
        peerID: LoomPeerID,
        peerName: String,
        state: State,
        transportKind: LoomTransportKind,
        connectedAt: Date,
        lastError: String? = nil
    ) {
        self.id = id
        self.peerID = peerID
        self.peerName = peerName
        self.state = state
        self.transportKind = transportKind
        self.connectedAt = connectedAt
        self.lastError = lastError
    }

    public init(
        id: UUID,
        peerID: UUID,
        peerAppID: String? = nil,
        peerName: String,
        state: State,
        transportKind: LoomTransportKind,
        connectedAt: Date,
        lastError: String? = nil
    ) {
        self.init(
            id: id,
            peerID: LoomPeerID(deviceID: peerID, appID: peerAppID),
            peerName: peerName,
            state: state,
            transportKind: transportKind,
            connectedAt: connectedAt,
            lastError: lastError
        )
    }
}

/// UI-friendly transfer snapshot exposed by ``LoomQuery`` and ``LoomContext``.
public struct LoomTransferSnapshot: Identifiable, Hashable, Sendable {
    /// Direction of transfer traffic relative to the local device.
    public enum Direction: String, Codable, Sendable {
        /// Transfer offered by the remote peer and received locally.
        case incoming
        /// Transfer initiated locally and sent to the remote peer.
        case outgoing
    }

    /// Stable transfer identifier.
    public let id: UUID
    /// Owning LoomKit connection identifier.
    public let connectionID: UUID
    /// Peer identifier associated with the transfer.
    public let peerID: LoomPeerID
    /// Logical app-defined transfer name.
    public let logicalName: String
    /// Direction of movement for the transfer.
    public let direction: Direction
    /// Current transfer state reported by Loom's transfer engine.
    public let state: LoomTransferState
    /// Number of bytes copied so far.
    public let bytesTransferred: UInt64
    /// Total bytes expected for the transfer.
    public let totalBytes: UInt64
    /// Optional MIME-style content type for UI hints.
    public let contentType: String?
    /// Optional destination or source file URL known to the handle.
    public let fileURL: URL?

    /// Creates a UI snapshot for a transfer flowing through a LoomKit connection handle.
    public init(
        id: UUID,
        connectionID: UUID,
        peerID: LoomPeerID,
        logicalName: String,
        direction: Direction,
        state: LoomTransferState,
        bytesTransferred: UInt64,
        totalBytes: UInt64,
        contentType: String?,
        fileURL: URL?
    ) {
        self.id = id
        self.connectionID = connectionID
        self.peerID = peerID
        self.logicalName = logicalName
        self.direction = direction
        self.state = state
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.contentType = contentType
        self.fileURL = fileURL
    }

    public init(
        id: UUID,
        connectionID: UUID,
        peerID: UUID,
        peerAppID: String? = nil,
        logicalName: String,
        direction: Direction,
        state: LoomTransferState,
        bytesTransferred: UInt64,
        totalBytes: UInt64,
        contentType: String?,
        fileURL: URL?
    ) {
        self.init(
            id: id,
            connectionID: connectionID,
            peerID: LoomPeerID(deviceID: peerID, appID: peerAppID),
            logicalName: logicalName,
            direction: direction,
            state: state,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            contentType: contentType,
            fileURL: fileURL
        )
    }
}

/// Per-connection event emitted by ``LoomConnectionHandle``.
public enum LoomConnectionEvent: Sendable {
    /// Reports a high-level state transition for the connection.
    case stateChanged(LoomConnectionSnapshot.State)
    /// Emits newly offered incoming transfers before acceptance.
    case incomingTransfer(LoomIncomingTransfer)
    /// Emits bytes received on the default LoomKit message stream.
    case message(Data)
    /// Reports final disconnection and optional error text.
    case disconnected(String?)
}
