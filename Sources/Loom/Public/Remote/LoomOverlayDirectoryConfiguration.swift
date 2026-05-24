//
//  LoomOverlayDirectoryConfiguration.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/11/26.
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
    /// Number of probe attempts made for each seed during one refresh.
    public let probeAttempts: Int
    /// Delay between retry attempts for a seed that did not respond.
    public let probeRetryDelay: Duration
    /// Policy used to rank direct transports when several seeds describe the same peer.
    public let directConnectionPolicy: LoomDirectConnectionPolicy
    package let usesDefaultProbePort: Bool

    public init(
        probePort: UInt16? = nil,
        refreshInterval: Duration = .seconds(30),
        probeTimeout: Duration = .seconds(2),
        directConnectionPolicy: LoomDirectConnectionPolicy = .default,
        seedProvider: @escaping SeedProvider
    ) {
        self.init(
            probePort: probePort,
            refreshInterval: refreshInterval,
            probeTimeout: probeTimeout,
            probeAttempts: 1,
            probeRetryDelay: .zero,
            directConnectionPolicy: directConnectionPolicy,
            seedProvider: seedProvider
        )
    }

    public init(
        probePort: UInt16? = nil,
        refreshInterval: Duration = .seconds(30),
        probeTimeout: Duration = .seconds(2),
        probeAttempts: Int,
        probeRetryDelay: Duration = .zero,
        directConnectionPolicy: LoomDirectConnectionPolicy = .default,
        seedProvider: @escaping SeedProvider
    ) {
        let usesDefaultProbePort = probePort == nil
        self.seedProvider = seedProvider
        self.probePort = probePort ?? Loom.defaultOverlayProbePort
        self.refreshInterval = refreshInterval
        self.probeTimeout = probeTimeout
        self.probeAttempts = max(1, probeAttempts)
        self.probeRetryDelay = probeRetryDelay
        self.directConnectionPolicy = directConnectionPolicy
        self.usesDefaultProbePort = usesDefaultProbePort
    }
}
