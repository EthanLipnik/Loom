//
//  LoomTransferModels.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import Foundation

/// Description of an opaque object transferred over Loom.
public struct LoomTransferOffer: Codable, Hashable, Sendable {
    /// Stable transfer identifier scoped to the authenticated Loom session.
    public let id: UUID
    /// App-owned display name for the object being transferred.
    public let logicalName: String
    /// Total object length in bytes.
    public let byteLength: UInt64
    /// Optional content type string supplied by the app.
    public let contentType: String?
    /// Optional lowercase SHA-256 digest for end-to-end integrity validation.
    public let sha256Hex: String?
    /// Opaque app-owned metadata carried with the transfer offer.
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        logicalName: String,
        byteLength: UInt64,
        contentType: String? = nil,
        sha256Hex: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.logicalName = logicalName
        self.byteLength = byteLength
        self.contentType = contentType
        self.sha256Hex = sha256Hex?.lowercased()
        self.metadata = metadata
    }
}

/// Lifecycle states emitted by Loom bulk transfers.
public enum LoomTransferState: String, Codable, Sendable {
    case offered
    case waitingForAcceptance
    case transferring
    case completed
    case cancelled
    case failed
    case declined
}

/// Progress event emitted for an incoming or outgoing Loom transfer.
public struct LoomTransferProgress: Sendable, Equatable {
    /// Identifier of the transfer associated with this event.
    public let transferID: UUID
    /// Logical name from the offer that produced this event.
    public let logicalName: String
    /// Number of bytes transferred so far.
    public let bytesTransferred: UInt64
    /// Total number of bytes expected for the transfer.
    public let totalBytes: UInt64
    /// Current lifecycle state for the transfer.
    public let state: LoomTransferState

    public init(
        transferID: UUID,
        logicalName: String,
        bytesTransferred: UInt64,
        totalBytes: UInt64,
        state: LoomTransferState
    ) {
        self.transferID = transferID
        self.logicalName = logicalName
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.state = state
    }
}

/// Errors specific to Loom bulk object transfer.
public enum LoomTransferError: LocalizedError, Sendable, Equatable {
    case declined
    case cancelled
    case missingControlStream
    case missingTransferState
    case invalidDataStreamLabel
    case integrityMismatch
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .declined:
            "The Loom transfer was declined."
        case .cancelled:
            "The Loom transfer was cancelled."
        case .missingControlStream:
            "The Loom transfer control stream is unavailable."
        case .missingTransferState:
            "The Loom transfer state could not be resolved."
        case .invalidDataStreamLabel:
            "The Loom transfer data stream label is invalid."
        case .integrityMismatch:
            "The Loom transfer failed integrity validation."
        case let .protocolViolation(message):
            message
        }
    }
}
