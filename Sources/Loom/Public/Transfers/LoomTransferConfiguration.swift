//
//  LoomTransferConfiguration.swift
//  Loom
//
//  Created by Codex on 3/10/26.
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

    public init(
        schedulerPolicy: LoomTransferSchedulerPolicy = .adaptiveHybrid,
        chunkSize: Int = 512 * 1024,
        perTransferWindowBytes: Int = 4 * 1024 * 1024,
        globalWindowBytes: Int = 32 * 1024 * 1024,
        smallObjectThresholdBytes: Int = 8 * 1024 * 1024
    ) {
        self.schedulerPolicy = schedulerPolicy
        self.chunkSize = max(16 * 1024, chunkSize)
        self.perTransferWindowBytes = max(self.chunkSize, perTransferWindowBytes)
        self.globalWindowBytes = max(self.perTransferWindowBytes, globalWindowBytes)
        self.smallObjectThresholdBytes = max(self.chunkSize, smallObjectThresholdBytes)
    }

    public static let `default` = LoomTransferConfiguration()
}
