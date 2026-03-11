//
//  LoomOverlayDirectoryConfiguration.swift
//  Loom
//
//  Created by Codex on 3/11/26.
//

import Foundation

/// Configuration for the seed-driven off-LAN Loom peer directory.
public struct LoomOverlayDirectoryConfiguration: Sendable {
    /// Async seed provider used to resolve overlay host names or IP addresses.
    public typealias SeedProvider = @Sendable () async throws -> [LoomOverlaySeed]

    /// Provider used to fetch current overlay seeds.
    public let seedProvider: SeedProvider
    /// Default TCP probe port used when a seed does not override it.
    public let probePort: UInt16
    /// Refresh interval for reloading and re-probing seeds.
    public let refreshInterval: Duration
    /// Per-seed timeout applied to the TCP probe.
    public let probeTimeout: Duration

    public init(
        probePort: UInt16 = Loom.defaultOverlayProbePort,
        refreshInterval: Duration = .seconds(30),
        probeTimeout: Duration = .seconds(2),
        seedProvider: @escaping SeedProvider
    ) {
        self.seedProvider = seedProvider
        self.probePort = probePort
        self.refreshInterval = refreshInterval
        self.probeTimeout = probeTimeout
    }
}
