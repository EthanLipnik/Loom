//
//  LoomTransferConfiguration.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

/// Scheduler behavior used for authenticated Loom bulk transfer.
public enum LoomTransferSchedulerPolicy: String, Codable, Sendable {
    case adaptiveHybrid
}

/// Configuration for Loom bulk object transfer behavior.
public struct LoomTransferConfiguration: Sendable, Hashable {
    /// Scheduler strategy used to decide how transfer work is interleaved.
    public var schedulerPolicy: LoomTransferSchedulerPolicy
    /// Maximum chunk size requested from sources and written to streams.
    public var chunkSize: Int
    /// Intended per-transfer in-flight window for bulk transfer scheduling.
    public var perTransferWindowBytes: Int
    /// Intended total in-flight window across all active transfers.
    public var globalWindowBytes: Int
    /// Remaining-byte threshold below which transfers are treated as latency-sensitive.
    public var smallObjectThresholdBytes: Int
    /// Maximum transfer offers retained in either direction for one authenticated session.
    public var maxActiveTransfersPerDirection: Int
    /// Maximum data streams retained while waiting for their matching transfer offer.
    public var maxPendingDataStreams: Int
    /// Maximum time a data stream may wait for its matching accepted transfer offer.
    public var pendingDataStreamTimeout: Duration
    /// Maximum time either peer may retain an offer without accepting or declining it.
    public var offerDecisionTimeout: Duration
    /// Maximum total lifetime of an accepted transfer before it must complete.
    public var activeTransferTimeout: Duration
    /// Maximum object size accepted in an offer.
    public var maxOfferByteLength: UInt64
    /// Maximum UTF-8 bytes accepted in an offer's logical name.
    public var maxOfferLogicalNameBytes: Int
    /// Maximum UTF-8 bytes accepted in an offer's content type.
    public var maxOfferContentTypeBytes: Int
    /// Maximum number of opaque metadata entries accepted in an offer.
    public var maxOfferMetadataEntries: Int
    /// Maximum aggregate UTF-8 bytes accepted across metadata keys and values.
    public var maxOfferMetadataBytes: Int
    /// Maximum encoded bytes accepted for one transfer control message before JSON decoding.
    public var maxControlMessageBytes: Int

    public init(
        schedulerPolicy: LoomTransferSchedulerPolicy = .adaptiveHybrid,
        chunkSize: Int = 512 * 1024,
        perTransferWindowBytes: Int = 4 * 1024 * 1024,
        globalWindowBytes: Int = 32 * 1024 * 1024,
        smallObjectThresholdBytes: Int = 8 * 1024 * 1024,
        maxActiveTransfersPerDirection: Int = 32,
        maxPendingDataStreams: Int = 32,
        pendingDataStreamTimeout: Duration = .seconds(10),
        offerDecisionTimeout: Duration = .seconds(120),
        activeTransferTimeout: Duration = .seconds(24 * 60 * 60),
        maxOfferByteLength: UInt64 = 64 * 1024 * 1024 * 1024,
        maxOfferLogicalNameBytes: Int = 4 * 1024,
        maxOfferContentTypeBytes: Int = 1024,
        maxOfferMetadataEntries: Int = 64,
        maxOfferMetadataBytes: Int = 64 * 1024,
        maxControlMessageBytes: Int = 256 * 1024
    ) {
        self.schedulerPolicy = schedulerPolicy
        self.chunkSize = max(16 * 1024, chunkSize)
        self.perTransferWindowBytes = max(self.chunkSize, perTransferWindowBytes)
        self.globalWindowBytes = max(self.perTransferWindowBytes, globalWindowBytes)
        self.smallObjectThresholdBytes = max(self.chunkSize, smallObjectThresholdBytes)
        self.maxActiveTransfersPerDirection = max(1, maxActiveTransfersPerDirection)
        self.maxPendingDataStreams = max(1, maxPendingDataStreams)
        self.pendingDataStreamTimeout = max(.milliseconds(1), pendingDataStreamTimeout)
        self.offerDecisionTimeout = max(.milliseconds(1), offerDecisionTimeout)
        self.activeTransferTimeout = max(.milliseconds(1), activeTransferTimeout)
        self.maxOfferByteLength = max(1, maxOfferByteLength)
        self.maxOfferLogicalNameBytes = max(1, maxOfferLogicalNameBytes)
        self.maxOfferContentTypeBytes = max(1, maxOfferContentTypeBytes)
        self.maxOfferMetadataEntries = max(1, maxOfferMetadataEntries)
        self.maxOfferMetadataBytes = max(1, maxOfferMetadataBytes)
        self.maxControlMessageBytes = max(1, maxControlMessageBytes)
    }

    public static let `default` = LoomTransferConfiguration()
}
