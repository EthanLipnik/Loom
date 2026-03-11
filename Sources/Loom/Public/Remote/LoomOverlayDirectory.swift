//
//  LoomOverlayDirectory.swift
//  Loom
//
//  Created by Codex on 3/11/26.
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

    /// Optional local device identifier used to filter self from directory output.
    public var localDeviceID: UUID?

    /// Callback invoked whenever the overlay peer set changes.
    public var onPeersChanged: (([LoomPeer]) -> Void)?

    private let configuration: LoomOverlayDirectoryConfiguration
    private var peersChangedObservers: [UUID: ([LoomPeer]) -> Void] = [:]
    private var refreshTask: Task<Void, Never>?

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
        isSearching = true
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
        discoveredPeers.removeAll()
        notifyPeersChanged()
    }

    /// Force an immediate seed refresh.
    public func refresh() async {
        await refreshNow()
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
        await refreshNow()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.refreshInterval)
            } catch {
                break
            }
            await refreshNow()
        }
    }

    private func refreshNow() async {
        do {
            let seeds = try await configuration.seedProvider()
            let candidates = await Self.probeCandidates(
                for: seeds,
                configuration: configuration
            )
            discoveredPeers = resolvePeers(from: candidates)
            isSearching = refreshTask != nil
            notifyPeersChanged()
        } catch {
            discoveredPeers.removeAll()
            isSearching = refreshTask != nil
            notifyPeersChanged()
            LoomLogger.debug(.transport, "Overlay directory refresh failed: \(error.localizedDescription)")
        }
    }

    private func resolvePeers(
        from candidates: [LoomOverlayDirectoryCandidate]
    ) -> [LoomPeer] {
        let candidatesByDeviceID = Dictionary(grouping: candidates, by: \.deviceID)

        var resolvedPeers: [LoomPeer] = []
        for (deviceID, deviceCandidates) in candidatesByDeviceID {
            guard deviceID != localDeviceID,
                  let preferredCandidate = deviceCandidates.min(by: Self.isPreferredCandidate(_:_:))
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
                        endpoint: Self.endpoint(
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
                    do {
                        let response = try await LoomOverlayProbeClient.probe(
                            seed: seed,
                            defaultPort: configuration.probePort,
                            timeout: configuration.probeTimeout
                        )
                        guard let deviceID = response.advertisement.deviceID,
                              !response.advertisement.directTransports.isEmpty else {
                            return nil
                        }
                        return LoomOverlayDirectoryCandidate(
                            deviceID: deviceID,
                            host: seed.host,
                            name: response.name,
                            deviceType: response.deviceType,
                            advertisement: response.advertisement
                        )
                    } catch {
                        return nil
                    }
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

    private static func endpoint(
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

    private static func isPreferredCandidate(
        _ lhs: LoomOverlayDirectoryCandidate,
        _ rhs: LoomOverlayDirectoryCandidate
    ) -> Bool {
        let leftHasQUIC = lhs.advertisement.directTransports.contains { $0.transportKind == .quic }
        let rightHasQUIC = rhs.advertisement.directTransports.contains { $0.transportKind == .quic }
        if leftHasQUIC != rightHasQUIC {
            return leftHasQUIC
        }
        return lhs.host < rhs.host
    }

    private static func isPreferredTransport(
        _ lhs: LoomDirectTransportAdvertisement,
        _ rhs: LoomDirectTransportAdvertisement
    ) -> Bool {
        transportRank(lhs.transportKind) < transportRank(rhs.transportKind)
    }

    private static func transportRank(_ transportKind: LoomTransportKind) -> Int {
        switch transportKind {
        case .quic:
            0
        case .tcp:
            1
        }
    }

    private func notifyPeersChanged() {
        onPeersChanged?(discoveredPeers)
        for observer in peersChangedObservers.values {
            observer(discoveredPeers)
        }
    }
}

private struct LoomOverlayDirectoryCandidate: Sendable {
    let deviceID: UUID
    let host: String
    let name: String
    let deviceType: DeviceType
    let advertisement: LoomPeerAdvertisement
}
