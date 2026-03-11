//
//  LoomConnectionCoordinator.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Network

/// Origin of a direct connection attempt chosen by the coordinator.
public enum LoomConnectionTargetSource: String, Sendable, Codable {
    case localDiscovery
    case overlayDirectory
    case relay
}

/// Candidate selected by the Loom connection coordinator.
public struct LoomConnectionTarget: Sendable {
    public let source: LoomConnectionTargetSource
    public let transportKind: LoomTransportKind
    public let endpoint: NWEndpoint

    public init(
        source: LoomConnectionTargetSource,
        transportKind: LoomTransportKind,
        endpoint: NWEndpoint
    ) {
        self.source = source
        self.transportKind = transportKind
        self.endpoint = endpoint
    }
}

/// Ordered direct-connect plan resolved from discovery and relay presence.
public struct LoomConnectionPlan: Sendable {
    public let targets: [LoomConnectionTarget]

    public init(targets: [LoomConnectionTarget]) {
        self.targets = targets
    }
}

/// Collects directly reachable candidates to publish through relay presence.
public enum LoomDirectCandidateCollector {
    public static func collect(
        configuration: LoomNetworkConfiguration,
        listeningPorts: [LoomTransportKind: UInt16] = [:],
        publicHostForTCP: String? = nil
    ) async -> [LoomRelayCandidate] {
        var candidates: [LoomRelayCandidate] = []
        let quicPort = listeningPorts[.quic] ?? configuration.quicPort
        let tcpPort = listeningPorts[.tcp] ?? configuration.controlPort

        if configuration.enabledDirectTransports.contains(.quic),
           quicPort > 0 {
            let quicProbe = await LoomSTUNProbe.run(localPort: quicPort)
            if quicProbe.reachable,
               let address = quicProbe.mappedAddress,
               let mappedPort = quicProbe.mappedPort {
                candidates.append(
                    LoomRelayCandidate(
                        transport: .quic,
                        address: address,
                        port: mappedPort
                    )
                )
            }
        }

        if configuration.enabledDirectTransports.contains(.tcp),
           tcpPort > 0,
           let publicHostForTCP {
            candidates.append(
                LoomRelayCandidate(
                    transport: .tcp,
                    address: publicHostForTCP,
                    port: tcpPort
                )
            )
        }

        return candidates
    }
}

/// Resolves and attempts authenticated Loom-native direct connections.
@MainActor
public final class LoomConnectionCoordinator {
    private let node: LoomNode
    private let relayClient: LoomRelayClient?
    private let policy: LoomDirectConnectionPolicy
    private let connector: @Sendable (LoomConnectionTarget, LoomSessionHelloRequest) async throws -> LoomAuthenticatedSession

    public init(
        node: LoomNode,
        relayClient: LoomRelayClient? = nil,
        policy: LoomDirectConnectionPolicy? = nil
    ) {
        self.node = node
        self.relayClient = relayClient
        self.policy = policy ?? node.configuration.directConnectionPolicy
        connector = { target, hello in
            try await node.connect(
                to: target.endpoint,
                using: target.transportKind,
                hello: hello
            )
        }
    }

    package init(
        node: LoomNode,
        relayClient: LoomRelayClient? = nil,
        policy: LoomDirectConnectionPolicy? = nil,
        connector: @escaping @Sendable (LoomConnectionTarget, LoomSessionHelloRequest) async throws -> LoomAuthenticatedSession
    ) {
        self.node = node
        self.relayClient = relayClient
        self.policy = policy ?? node.configuration.directConnectionPolicy
        self.connector = connector
    }

    nonisolated package static func relayFallbackSessionID(
        advertisedRelaySessionID: String?,
        localPeer: LoomPeer?,
        overlayPeer _: LoomPeer?
    ) -> String? {
        guard localPeer == nil else {
            return nil
        }
        return advertisedRelaySessionID
    }

    public func makePlan(
        localPeer: LoomPeer? = nil,
        overlayPeer: LoomPeer? = nil,
        relaySessionID: String? = nil
    ) async throws -> LoomConnectionPlan {
        var targets: [LoomConnectionTarget] = []

        if let localPeer {
            targets.append(
                contentsOf: Self.discoveryTargets(
                    from: localPeer,
                    source: .localDiscovery,
                    policy: policy
                )
            )
        }

        if let overlayPeer {
            targets.append(
                contentsOf: Self.discoveryTargets(
                    from: overlayPeer,
                    source: .overlayDirectory,
                    policy: policy
                )
            )
        }

        if let relaySessionID,
           let relayClient {
            let presence = try await relayClient.fetchPresence(sessionID: relaySessionID)
            let relayTargets = presence.peerCandidates
                .sorted(by: compareRelayCandidates(_:_:))
                .compactMap(Self.target(from:))
            targets.append(contentsOf: relayTargets)
        }

        return LoomConnectionPlan(targets: targets)
    }

    public func connect(
        hello: LoomSessionHelloRequest,
        localPeer: LoomPeer? = nil,
        overlayPeer: LoomPeer? = nil,
        relaySessionID: String? = nil
    ) async throws -> LoomAuthenticatedSession {
        let plan = try await makePlan(
            localPeer: localPeer,
            overlayPeer: overlayPeer,
            relaySessionID: relaySessionID
        )
        guard !plan.targets.isEmpty else {
            throw LoomError.sessionNotFound
        }

        var lastError: Error?
        for batch in connectionBatches(from: plan) {
            do {
                let resolved = try await connect(batch: batch, hello: hello)
                recordConnectedTarget(resolved.target, session: resolved.session)
                recordRaceSelectionIfNeeded(for: batch, winner: resolved.target)
                return resolved.session
            } catch {
                lastError = error
            }
        }

        throw lastError ?? LoomError.sessionNotFound
    }

    public func connect(
        to target: LoomConnectionTarget,
        hello: LoomSessionHelloRequest
    ) async throws -> LoomAuthenticatedSession {
        try await connector(target, hello)
    }

    private func compareRelayCandidates(
        _ lhs: LoomRelayCandidate,
        _ rhs: LoomRelayCandidate
    ) -> Bool {
        let leftPriority = relayPriority(lhs.transport)
        let rightPriority = relayPriority(rhs.transport)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        if lhs.address != rhs.address {
            return lhs.address < rhs.address
        }
        return lhs.port < rhs.port
    }

    private func relayPriority(_ transport: LoomRelayCandidateTransport) -> Int {
        let transportKind: LoomTransportKind = switch transport {
        case .quic: .quic
        case .tcp: .tcp
        }
        return policy.preferredRemoteTransportOrder.firstIndex(of: transportKind) ?? Int.max
    }

    private static func target(from candidate: LoomRelayCandidate) -> LoomConnectionTarget? {
        guard let endpointPort = NWEndpoint.Port(rawValue: candidate.port) else {
            return nil
        }
        let host = NWEndpoint.Host(candidate.address)
        let transportKind: LoomTransportKind = switch candidate.transport {
        case .quic: .quic
        case .tcp: .tcp
        }
        return LoomConnectionTarget(
            source: .relay,
            transportKind: transportKind,
            endpoint: .hostPort(host: host, port: endpointPort)
        )
    }

    private static func discoveryTargets(
        from peer: LoomPeer,
        source: LoomConnectionTargetSource,
        policy: LoomDirectConnectionPolicy
    ) -> [LoomConnectionTarget] {
        let advertisedTransports = peer.advertisement.directTransports
        let transports = advertisedTransports.isEmpty
            ? [LoomDirectTransportAdvertisement(transportKind: .tcp, port: 0)]
            : advertisedTransports.sorted { lhs, rhs in
                let leftPathIndex = policy.preferredLocalPathOrder.firstIndex(of: lhs.pathKind ?? .other) ?? Int.max
                let rightPathIndex = policy.preferredLocalPathOrder.firstIndex(of: rhs.pathKind ?? .other) ?? Int.max
                if leftPathIndex != rightPathIndex {
                    return leftPathIndex < rightPathIndex
                }
                let leftIndex = policy.preferredRemoteTransportOrder.firstIndex(of: lhs.transportKind) ?? Int.max
                let rightIndex = policy.preferredRemoteTransportOrder.firstIndex(of: rhs.transportKind) ?? Int.max
                if leftIndex != rightIndex {
                    return leftIndex < rightIndex
                }
                return lhs.port < rhs.port
            }

        return transports.map { transport in
            LoomConnectionTarget(
                source: source,
                transportKind: transport.transportKind,
                endpoint: localEndpoint(
                    from: peer.endpoint,
                    advertisedPort: transport.port
                )
            )
        }
    }

    private static func localEndpoint(
        from endpoint: NWEndpoint,
        advertisedPort: UInt16
    ) -> NWEndpoint {
        guard advertisedPort > 0 else {
            return endpoint
        }
        guard case let .hostPort(host, _) = endpoint,
              let port = NWEndpoint.Port(rawValue: advertisedPort) else {
            return endpoint
        }
        return .hostPort(host: host, port: port)
    }

    private func connectionBatches(from plan: LoomConnectionPlan) -> [[LoomConnectionTarget]] {
        var batches: [[LoomConnectionTarget]] = []

        for target in plan.targets {
            let shouldRaceTargets = shouldRace(source: target.source)
            if shouldRaceTargets,
               var lastBatch = batches.last,
               let lastTarget = lastBatch.first,
               lastTarget.source == target.source {
                lastBatch.append(target)
                batches[batches.count - 1] = lastBatch
                continue
            }
            batches.append([target])
        }

        return batches
    }

    private func shouldRace(source: LoomConnectionTargetSource) -> Bool {
        switch source {
        case .localDiscovery:
            policy.racesLocalCandidates
        case .overlayDirectory:
            policy.racesRemoteCandidates
        case .relay:
            policy.racesRemoteCandidates
        }
    }

    private func connect(
        batch: [LoomConnectionTarget],
        hello: LoomSessionHelloRequest
    ) async throws -> LoomResolvedConnection {
        guard let firstTarget = batch.first else {
            throw LoomError.sessionNotFound
        }
        guard batch.count > 1,
              shouldRace(source: firstTarget.source) else {
            return try await connectSequentially(batch: batch, hello: hello)
        }

        recordRaceStarted(for: firstTarget.source, attemptCount: batch.count)

        return try await withThrowingTaskGroup(of: LoomConnectionAttemptResult.self) { group in
            for (index, target) in batch.enumerated() {
                let delay = raceDelay(for: target.source, attemptIndex: index)
                group.addTask { [connector] in
                    do {
                        if delay != .zero {
                            try await Task.sleep(for: delay)
                        }
                        let session = try await connector(target, hello)
                        return .success(
                            LoomResolvedConnection(
                                target: target,
                                session: session
                            )
                        )
                    } catch is CancellationError {
                        return .cancelled(target)
                    } catch {
                        return .failure(target, error)
                    }
                }
            }

            var winner: LoomResolvedConnection?
            var lastError: Error?

            while let result = try await group.next() {
                switch result {
                case let .success(connection):
                    if winner == nil {
                        winner = connection
                        group.cancelAll()
                    } else {
                        await connection.session.cancel()
                    }

                case let .failure(target, error):
                    recordFailedTarget(target)
                    lastError = error

                case let .cancelled(target):
                    recordCancelledTarget(target)
                }
            }

            guard let winner else {
                recordSourceExhausted(firstTarget.source)
                throw lastError ?? LoomError.sessionNotFound
            }

            return winner
        }
    }

    private func connectSequentially(
        batch: [LoomConnectionTarget],
        hello: LoomSessionHelloRequest
    ) async throws -> LoomResolvedConnection {
        var lastError: Error?

        for target in batch {
            do {
                let session = try await connector(target, hello)
                return LoomResolvedConnection(
                    target: target,
                    session: session
                )
            } catch {
                recordFailedTarget(target)
                lastError = error
            }
        }

        if let source = batch.first?.source {
            recordSourceExhausted(source)
        }
        throw lastError ?? LoomError.sessionNotFound
    }

    private func raceDelay(
        for source: LoomConnectionTargetSource,
        attemptIndex: Int
    ) -> Duration {
        guard attemptIndex > 0 else {
            return .zero
        }
        let staggerMilliseconds = switch source {
        case .localDiscovery:
            75
        case .overlayDirectory:
            150
        case .relay:
            150
        }
        return .milliseconds(staggerMilliseconds * attemptIndex)
    }

    private func recordRaceStarted(
        for source: LoomConnectionTargetSource,
        attemptCount: Int
    ) {
        LoomInstrumentation.record(
            LoomStepEvent(
                rawValue: "loom.connection.race.\(source.rawValue).started.\(attemptCount)"
            )
        )
        LoomLogger.debug(
            .transport,
            "Racing \(attemptCount) Loom \(source.rawValue) candidates"
        )
    }

    private func recordRaceSelectionIfNeeded(
        for batch: [LoomConnectionTarget],
        winner: LoomConnectionTarget
    ) {
        guard batch.count > 1 else {
            return
        }
        LoomInstrumentation.record(
            LoomStepEvent(
                rawValue: "loom.connection.race.\(winner.source.rawValue).selected.\(winner.transportKind.rawValue)"
            )
        )
        LoomLogger.log(
            .transport,
            "Selected Loom \(winner.transportKind.rawValue) candidate from \(winner.source.rawValue) raceSize=\(batch.count)"
        )
    }

    private func recordFailedTarget(_ target: LoomConnectionTarget) {
        LoomInstrumentation.record(
            LoomStepEvent(
                rawValue: "loom.connection.failed.\(target.source.rawValue).\(target.transportKind.rawValue)"
            )
        )
        LoomLogger.debug(
            .transport,
            "Failed Loom connection candidate source=\(target.source.rawValue) transport=\(target.transportKind.rawValue)"
        )
    }

    private func recordSourceExhausted(_ source: LoomConnectionTargetSource) {
        LoomInstrumentation.record(
            LoomStepEvent(
                rawValue: "loom.connection.exhausted.\(source.rawValue)"
            )
        )
        LoomLogger.debug(
            .transport,
            "Exhausted Loom \(source.rawValue) connection candidates"
        )
    }

    private func recordCancelledTarget(_ target: LoomConnectionTarget) {
        LoomInstrumentation.record(
            LoomStepEvent(
                rawValue: "loom.connection.race.cancelled.\(target.source.rawValue).\(target.transportKind.rawValue)"
            )
        )
    }

    private func recordConnectedTarget(
        _ target: LoomConnectionTarget,
        session: LoomAuthenticatedSession
    ) {
        guard let path = session.rawSession.connection.currentPath else {
            LoomInstrumentation.record(
                LoomStepEvent(
                    rawValue: "loom.connection.connected.\(target.source.rawValue).\(target.transportKind.rawValue).unknown"
                )
            )
            return
        }
        let snapshot = LoomNetworkPathClassifier.classify(path)
        LoomInstrumentation.record(
            LoomStepEvent(
                rawValue: "loom.connection.connected.\(target.source.rawValue).\(target.transportKind.rawValue).\(snapshot.kind.rawValue)"
            )
        )
    }
}

private struct LoomResolvedConnection {
    let target: LoomConnectionTarget
    let session: LoomAuthenticatedSession
}

private enum LoomConnectionAttemptResult {
    case success(LoomResolvedConnection)
    case failure(LoomConnectionTarget, Error)
    case cancelled(LoomConnectionTarget)
}
