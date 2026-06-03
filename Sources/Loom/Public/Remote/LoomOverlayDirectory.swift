//
//  LoomOverlayDirectory.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import Network
import Observation

/// Seed-driven off-LAN Loom peer directory for overlay and VPN-style networks.
@Observable
@MainActor
public final class LoomOverlayDirectory {
    /// Current peers resolved from overlay seeds.
    public private(set) var discoveredPeers: [LoomPeer] = []

    /// Whether the directory is actively refreshing seeds.
    public private(set) var isSearching = false

    /// Whether refresh requests are currently paused while preserving discovered peers.
    public private(set) var isRefreshPaused = false

    /// Optional local device identifier used to filter self from directory output.
    public var localDeviceID: UUID?

    /// Callback invoked whenever the overlay peer set changes.
    public var onPeersChanged: (([LoomPeer]) -> Void)?

    private let configuration: LoomOverlayDirectoryConfiguration
    private var peersChangedObservers: [UUID: ([LoomPeer]) -> Void] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshProcessorTask: Task<Void, Never>?
    private var requestedRefreshGeneration = 0
    private var completedRefreshGeneration = 0
    private var lastPublishedPeerSnapshots: [PublishedPeerSnapshot] = []
    private let clock = ContinuousClock()
    private var retainedPeersByID: [LoomPeerID: RetainedOverlayPeer] = [:]

    public init(
        configuration: LoomOverlayDirectoryConfiguration,
        localDeviceID: UUID? = nil
    ) {
        self.configuration = configuration
        self.localDeviceID = localDeviceID
    }

    /// Start polling seeds and probing overlay hosts.
    public func start() {
        guard refreshTask == nil else {
            return
        }
        isSearching = !isRefreshPaused
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshLoop()
        }
    }

    /// Stop polling and clear the current peer set.
    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isSearching = false
        publishDiscoveredPeers([])
    }

    /// Pause periodic and manual refresh work without clearing discovered peers.
    public func pauseRefreshes() {
        guard !isRefreshPaused else { return }
        isRefreshPaused = true
        refreshProcessorTask?.cancel()
        refreshProcessorTask = nil
        completedRefreshGeneration = requestedRefreshGeneration
        isSearching = false
    }

    /// Resume refresh work and optionally perform one coalesced refresh.
    public func resumeRefreshes(performRefresh: Bool = true) {
        guard isRefreshPaused else { return }
        isRefreshPaused = false
        isSearching = refreshTask != nil
        guard performRefresh else { return }
        Task { @MainActor [weak self] in
            await self?.requestRefresh()
        }
    }

    /// Force an immediate seed refresh.
    public func refresh() async {
        await requestRefresh()
    }

    /// Registers an observer that is invoked whenever discovered peers change.
    @discardableResult
    public func addPeersChangedObserver(_ observer: @escaping ([LoomPeer]) -> Void) -> UUID {
        let token = UUID()
        peersChangedObservers[token] = observer
        return token
    }

    /// Removes a previously-registered peer-change observer.
    public func removePeersChangedObserver(_ token: UUID) {
        peersChangedObservers.removeValue(forKey: token)
    }

    private func runRefreshLoop() async {
        await requestRefresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.refreshInterval)
            } catch {
                break
            }
            await requestRefresh()
        }
    }

    private func requestRefresh() async {
        guard !isRefreshPaused else { return }
        requestedRefreshGeneration += 1
        let targetGeneration = requestedRefreshGeneration
        startRefreshProcessorIfNeeded()

        while completedRefreshGeneration < targetGeneration {
            guard let refreshProcessorTask else { return }
            await refreshProcessorTask.value
        }
    }

    private func startRefreshProcessorIfNeeded() {
        guard refreshProcessorTask == nil else { return }

        refreshProcessorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRefreshProcessor()
        }
    }

    private func runRefreshProcessor() async {
        defer {
            refreshProcessorTask = nil
            isSearching = refreshTask != nil && !isRefreshPaused
        }

        while completedRefreshGeneration < requestedRefreshGeneration, !Task.isCancelled, !isRefreshPaused {
            let generation = requestedRefreshGeneration
            await refreshNow(generation: generation)
            completedRefreshGeneration = max(completedRefreshGeneration, generation)
        }
    }

    private func refreshNow(generation: Int) async {
        guard !isRefreshPaused else { return }
        isSearching = true
        do {
            let seeds = try await configuration.seedProvider()
            guard !Task.isCancelled, !isRefreshPaused else { return }
            LoomLogger.debug(
                .transport,
                "Overlay directory refresh \(generation) started: seeds=\(seeds.count) attempts=\(configuration.probeAttempts)"
            )
            guard !seeds.isEmpty else {
                retainedPeersByID.removeAll()
                publishDiscoveredPeers([])
                isSearching = refreshTask != nil && !isRefreshPaused
                LoomLogger.debug(
                    .transport,
                    "Overlay directory refresh \(generation) completed: seeds=0 peers=0"
                )
                return
            }
            let candidates = await Self.probeCandidates(
                for: seeds,
                configuration: configuration
            )
            guard !Task.isCancelled, !isRefreshPaused else { return }
            let resolvedPeers = resolvePeers(from: candidates)
            let publishedPeers = peersByRetainingRecentResolvedPeers(
                resolvedPeers,
                matching: seeds,
                now: clock.now
            )
            publishDiscoveredPeers(publishedPeers)
            isSearching = refreshTask != nil && !isRefreshPaused
            LoomLogger.debug(
                .transport,
                "Overlay directory refresh \(generation) completed: candidates=\(candidates.count) " +
                    "resolvedPeers=\(resolvedPeers.count) peers=\(discoveredPeers.count)"
            )
        } catch {
            guard !Task.isCancelled, !isRefreshPaused else { return }
            let retainedPeers = retainedPeersAfterSeedRefreshFailure(now: clock.now)
            publishDiscoveredPeers(retainedPeers)
            isSearching = refreshTask != nil && !isRefreshPaused
            LoomLogger.debug(
                .transport,
                "Overlay directory refresh \(generation) failed: \(Self.probeFailureSummary(error)); " +
                    "retainedPeers=\(retainedPeers.count)"
            )
        }
    }

    private func peersByRetainingRecentResolvedPeers(
        _ resolvedPeers: [LoomPeer],
        matching seeds: [LoomOverlaySeed],
        now: ContinuousClock.Instant
    ) -> [LoomPeer] {
        if !resolvedPeers.isEmpty {
            for peer in resolvedPeers {
                retainedPeersByID[peer.id] = RetainedOverlayPeer(peer: peer, observedAt: now)
            }
            pruneRetainedPeers(matching: seeds, now: now)
            return resolvedPeers
        }

        let retainedPeers = retainedPeersMatchingCurrentSeeds(seeds, now: now)
        if !retainedPeers.isEmpty {
            LoomLogger.debug(
                .transport,
                "Overlay directory retained \(retainedPeers.count) peer(s) after empty probe result"
            )
        }
        return retainedPeers
    }

    private func retainedPeersMatchingCurrentSeeds(
        _ seeds: [LoomOverlaySeed],
        now: ContinuousClock.Instant
    ) -> [LoomPeer] {
        pruneRetainedPeers(matching: seeds, now: now)
        return sortedRetainedPeers()
    }

    private func retainedPeersAfterSeedRefreshFailure(now: ContinuousClock.Instant) -> [LoomPeer] {
        pruneRetainedPeers(matchingSeedHosts: nil, now: now)
        if !retainedPeersByID.isEmpty {
            LoomLogger.debug(
                .transport,
                "Overlay directory retained \(retainedPeersByID.count) peer(s) after seed refresh failure"
            )
        }
        return sortedRetainedPeers()
    }

    private func sortedRetainedPeers() -> [LoomPeer] {
        return retainedPeersByID.values
            .map(\.peer)
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    private func pruneRetainedPeers(
        matching seeds: [LoomOverlaySeed],
        now: ContinuousClock.Instant
    ) {
        let seedHosts = Set(
            seeds.map { $0.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        pruneRetainedPeers(matchingSeedHosts: seedHosts, now: now)
    }

    private func pruneRetainedPeers(
        matchingSeedHosts seedHosts: Set<String>?,
        now: ContinuousClock.Instant
    ) {
        for (peerID, retainedPeer) in retainedPeersByID {
            let age = retainedPeer.observedAt.duration(to: now)
            guard age <= configuration.retainedPeerExpiration else {
                retainedPeersByID.removeValue(forKey: peerID)
                continue
            }
            if let seedHosts,
               !seedHosts.contains(Self.endpointHostKey(for: retainedPeer.peer)) {
                retainedPeersByID.removeValue(forKey: peerID)
            }
        }
    }

    private func resolvePeers(
        from candidates: [LoomOverlayDirectoryCandidate]
    ) -> [LoomPeer] {
        let candidatesByDeviceID = Dictionary(grouping: candidates, by: \.deviceID)

        var resolvedPeers: [LoomPeer] = []
        for (deviceID, deviceCandidates) in candidatesByDeviceID {
            guard deviceID != localDeviceID,
                  let preferredCandidate = deviceCandidates.min(by: isPreferredCandidate(_:_:))
            else {
                continue
            }

            let projections = LoomHostCatalogCodec.projections(
                peerName: preferredCandidate.name,
                advertisement: preferredCandidate.advertisement
            )
            for projection in projections {
                resolvedPeers.append(
                    LoomPeer(
                        id: projection.peerID,
                        name: projection.displayName,
                        deviceType: preferredCandidate.deviceType,
                        endpoint: endpoint(
                            host: preferredCandidate.host,
                            advertisement: projection.advertisement
                        ),
                        advertisement: projection.advertisement
                    )
                )
            }
        }

        return resolvedPeers.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private static func probeCandidates(
        for seeds: [LoomOverlaySeed],
        configuration: LoomOverlayDirectoryConfiguration
    ) async -> [LoomOverlayDirectoryCandidate] {
        await withTaskGroup(of: LoomOverlayDirectoryCandidate?.self) { group in
            for seed in seeds where seed.host.isEmpty == false {
                group.addTask {
                    await probeCandidate(seed: seed, configuration: configuration)
                }
            }

            var candidates: [LoomOverlayDirectoryCandidate] = []
            for await candidate in group {
                if let candidate {
                    candidates.append(candidate)
                }
            }
            return candidates
        }
    }

    private static func probeCandidate(
        seed: LoomOverlaySeed,
        configuration: LoomOverlayDirectoryConfiguration
    ) async -> LoomOverlayDirectoryCandidate? {
        for attempt in 1...configuration.probeAttempts {
            do {
                let response = try await LoomOverlayProbeClient.probe(
                    seed: seed,
                    defaultPort: configuration.probePort,
                    timeout: configuration.probeTimeout
                )
                guard let deviceID = response.advertisement.deviceID,
                      !response.advertisement.directTransports.isEmpty else {
                    LoomLogger.debug(
                        .transport,
                        "Overlay seed \(seed.host):\(Self.probePort(for: seed, configuration: configuration)) " +
                            "ignored on attempt \(attempt): " +
                            "missingDeviceID=\(response.advertisement.deviceID == nil) " +
                            "directTransports=\(response.advertisement.directTransports.count)"
                    )
                    return nil
                }
                if attempt > 1 {
                    LoomLogger.debug(
                        .transport,
                        "Overlay seed \(seed.host):\(Self.probePort(for: seed, configuration: configuration)) " +
                            "succeeded on attempt \(attempt) " +
                            "directTransports=\(directTransportSummary(for: response.advertisement))"
                    )
                }
                return LoomOverlayDirectoryCandidate(
                    deviceID: deviceID,
                    host: seed.host,
                    name: response.name,
                    deviceType: response.deviceType,
                    advertisement: response.advertisement
                )
            } catch {
                if attempt >= configuration.probeAttempts {
                    LoomLogger.debug(
                        .transport,
                        "Overlay seed \(seed.host):\(Self.probePort(for: seed, configuration: configuration)) " +
                            "failed after \(attempt) attempt(s) " +
                            "timeout=\(configuration.probeTimeout) " +
                            "reason=\(probeFailureSummary(error))"
                    )
                    return nil
                }

                LoomLogger.debug(
                    .transport,
                    "Overlay seed \(seed.host):\(Self.probePort(for: seed, configuration: configuration)) " +
                        "failed attempt \(attempt); retrying after \(configuration.probeRetryDelay) " +
                        "reason=\(probeFailureSummary(error))"
                )
                do {
                    try await Task.sleep(for: configuration.probeRetryDelay)
                } catch {
                    return nil
                }
            }
        }

        return nil
    }

    private static func probePort(
        for seed: LoomOverlaySeed,
        configuration: LoomOverlayDirectoryConfiguration
    ) -> UInt16 {
        seed.probePort ?? configuration.probePort
    }

    private static func probeFailureSummary(_ error: Error) -> String {
        let failure = LoomConnectionFailure.classify(error)
        let code = failure.posixCode.map { " posix=\($0.rawValue)" } ?? ""
        let detail = failure.detail.map { " detail=\($0)" } ?? ""
        return "\(failure.reason.rawValue)\(code)\(detail)"
    }

    private static func directTransportSummary(for advertisement: LoomPeerAdvertisement) -> String {
        let summary = advertisement.directTransports
            .map { "\($0.transportKind.rawValue):\($0.port)" }
            .joined(separator: ",")
        return summary.isEmpty ? "none" : summary
    }

    private static func endpointHostKey(for peer: LoomPeer) -> String {
        guard case let .hostPort(host, _) = peer.endpoint else {
            return ""
        }
        return String(describing: host).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func endpoint(
        host: String,
        advertisement: LoomPeerAdvertisement
    ) -> NWEndpoint {
        let preferredTransport = advertisement.directTransports.min(by: isPreferredTransport(_:_:))
        let endpointPort = NWEndpoint.Port(rawValue: preferredTransport?.port ?? 0) ?? .any
        return .hostPort(
            host: .init(host),
            port: endpointPort
        )
    }

    private func isPreferredCandidate(
        _ lhs: LoomOverlayDirectoryCandidate,
        _ rhs: LoomOverlayDirectoryCandidate
    ) -> Bool {
        let leftPreferredTransport = lhs.advertisement.directTransports.min(by: isPreferredTransport(_:_:))
        let rightPreferredTransport = rhs.advertisement.directTransports.min(by: isPreferredTransport(_:_:))
        switch (leftPreferredTransport, rightPreferredTransport) {
        case let (left?, right?):
            if isPreferredTransport(left, right) {
                return true
            }
            if isPreferredTransport(right, left) {
                return false
            }
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            break
        }
        return lhs.host < rhs.host
    }

    private func isPreferredTransport(
        _ lhs: LoomDirectTransportAdvertisement,
        _ rhs: LoomDirectTransportAdvertisement
    ) -> Bool {
        let leftPathIndex = pathRank(lhs.pathKind)
        let rightPathIndex = pathRank(rhs.pathKind)
        if leftPathIndex != rightPathIndex {
            return leftPathIndex < rightPathIndex
        }
        let leftTransportIndex = transportRank(lhs.transportKind)
        let rightTransportIndex = transportRank(rhs.transportKind)
        if leftTransportIndex != rightTransportIndex {
            return leftTransportIndex < rightTransportIndex
        }
        return lhs.port < rhs.port
    }

    private func pathRank(_ pathKind: LoomDirectPathKind?) -> Int {
        configuration.directConnectionPolicy.preferredLocalPathOrder.firstIndex(of: pathKind ?? .other) ?? Int.max
    }

    private func transportRank(_ transportKind: LoomTransportKind) -> Int {
        configuration.directConnectionPolicy.preferredTransportOrder.firstIndex(of: transportKind) ?? Int.max
    }

    private func publishDiscoveredPeers(_ peers: [LoomPeer]) {
        let snapshots = peers.map(PublishedPeerSnapshot.init)
        guard snapshots != lastPublishedPeerSnapshots else { return }

        discoveredPeers = peers
        lastPublishedPeerSnapshots = snapshots
        onPeersChanged?(peers)
        for observer in peersChangedObservers.values {
            observer(peers)
        }
    }
}

private struct PublishedPeerSnapshot: Equatable {
    let id: LoomPeerID
    let name: String
    let deviceType: DeviceType
    let endpoint: NWEndpoint
    let advertisement: LoomPeerAdvertisement
    let resolvedAddresses: [NWEndpoint.Host]

    init(_ peer: LoomPeer) {
        id = peer.id
        name = peer.name
        deviceType = peer.deviceType
        endpoint = peer.endpoint
        advertisement = peer.advertisement
        resolvedAddresses = peer.resolvedAddresses
    }
}

private struct RetainedOverlayPeer {
    let peer: LoomPeer
    let observedAt: ContinuousClock.Instant
}

private struct LoomOverlayDirectoryCandidate: Sendable {
    let deviceID: UUID
    let host: String
    let name: String
    let deviceType: DeviceType
    let advertisement: LoomPeerAdvertisement
}
