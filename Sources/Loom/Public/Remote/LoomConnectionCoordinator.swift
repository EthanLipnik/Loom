//
//  LoomConnectionCoordinator.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Network

/// Origin of a direct connection attempt chosen by the coordinator.
public enum LoomConnectionTargetSource: String, Sendable, Codable {
    case localDiscovery
    case overlayDirectory
    case remoteSignaling
}

/// Candidate selected by the Loom connection coordinator.
public struct LoomConnectionTarget: Sendable {
    public let source: LoomConnectionTargetSource
    public let transportKind: LoomTransportKind
    public let endpoint: NWEndpoint
    public let requiredLocalPort: UInt16?
    public let expectedIdentityKeyID: String?
    public let expectedIdentityPublicKey: Data?

    public init(
        source: LoomConnectionTargetSource,
        transportKind: LoomTransportKind,
        endpoint: NWEndpoint,
        requiredLocalPort: UInt16? = nil,
        expectedIdentityKeyID: String? = nil,
        expectedIdentityPublicKey: Data? = nil
    ) {
        self.source = source
        self.transportKind = transportKind
        self.endpoint = endpoint
        self.requiredLocalPort = requiredLocalPort
        self.expectedIdentityKeyID = expectedIdentityKeyID
        self.expectedIdentityPublicKey = expectedIdentityPublicKey
    }
}

/// Ordered direct-connect plan resolved from discovery and remote signaling presence.
public struct LoomConnectionPlan: Sendable {
    public let targets: [LoomConnectionTarget]

    public init(targets: [LoomConnectionTarget]) {
        self.targets = targets
    }
}

/// Collects directly reachable candidates to publish through remote signaling presence.
public enum LoomDirectCandidateCollector {
    public static func collect(
        configuration: LoomNetworkConfiguration,
        listeningPorts: [LoomTransportKind: UInt16] = [:],
        publicHostForTCP: String? = nil
    ) async -> [LoomRemoteCandidate] {
        var candidates: [LoomRemoteCandidate] = []
        let udpPort = listeningPorts[.udp] ?? configuration.udpPort
        let quicPort = listeningPorts[.quic] ?? configuration.quicPort
        let tcpPort = listeningPorts[.tcp] ?? configuration.controlPort

        if configuration.enabledDirectTransports.contains(.udp),
           udpPort > 0,
           let candidate = await mappedDatagramCandidate(
                transportKind: .udp,
                localPort: udpPort
           ) {
            candidates.append(candidate)
        }

        if configuration.enabledDirectTransports.contains(.quic),
           quicPort > 0,
           let candidate = await mappedDatagramCandidate(
                transportKind: .quic,
                localPort: quicPort
           ) {
            candidates.append(candidate)
        }

        if configuration.enabledDirectTransports.contains(.tcp),
           tcpPort > 0,
           let publicHostForTCP {
            candidates.append(
                LoomRemoteCandidate(
                    transport: .tcp,
                    address: publicHostForTCP,
                    port: tcpPort
                )
            )
        }

        return candidates
    }

    private static func mappedDatagramCandidate(
        transportKind: LoomTransportKind,
        localPort: UInt16
    ) async -> LoomRemoteCandidate? {
        guard transportKind.usesDatagramPath else {
            return nil
        }
        let probe = await LoomSTUNProbe.run(localPort: localPort)
        guard probe.reachable,
              let address = probe.mappedAddress,
              let mappedPort = probe.mappedPort else {
            return nil
        }
        return LoomRemoteCandidate(
            transport: transportKind,
            address: address,
            port: mappedPort
        )
    }
}

/// Resolves and attempts authenticated Loom-native direct connections.
@MainActor
public final class LoomConnectionCoordinator {
    private let node: LoomNode
    private let signalingClient: LoomRemoteSignalingClient?
    private let policy: LoomDirectConnectionPolicy
    private let connector: @Sendable (LoomConnectionTarget, LoomSessionHelloRequest) async throws -> LoomAuthenticatedSession

    public init(
        node: LoomNode,
        signalingClient: LoomRemoteSignalingClient? = nil,
        policy: LoomDirectConnectionPolicy? = nil
    ) {
        self.node = node
        self.signalingClient = signalingClient
        self.policy = policy ?? node.configuration.directConnectionPolicy
        connector = { target, hello in
                try await node.connect(
                    to: target.endpoint,
                    using: target.transportKind,
                    hello: hello,
                    requiredLocalPort: target.requiredLocalPort,
                    expectedPeerIdentityKeyID: target.expectedIdentityKeyID,
                    expectedPeerIdentityPublicKey: target.expectedIdentityPublicKey
                )
            }
    }

    public init(
        node: LoomNode,
        signalingClient: LoomRemoteSignalingClient? = nil,
        policy: LoomDirectConnectionPolicy? = nil,
        connector: @escaping @Sendable (LoomConnectionTarget, LoomSessionHelloRequest) async throws -> LoomAuthenticatedSession
    ) {
        self.node = node
        self.signalingClient = signalingClient
        self.policy = policy ?? node.configuration.directConnectionPolicy
        self.connector = connector
    }

    nonisolated package static func signalingFallbackSessionID(
        advertisedSignalingSessionID: String?,
        localPeer: LoomPeer?
    ) -> String? {
        guard localPeer == nil else {
            return nil
        }
        return advertisedSignalingSessionID
    }

    public func makePlan(
        localPeer: LoomPeer? = nil,
        overlayPeer: LoomPeer? = nil,
        signalingSessionID: String? = nil,
        requiredLocalPort: UInt16? = nil
    ) async throws -> LoomConnectionPlan {
        var targets: [LoomConnectionTarget] = []

        if let localPeer {
            targets.append(
                contentsOf: Self.discoveryTargets(
                    from: localPeer,
                    source: .localDiscovery,
                    policy: policy,
                    hostOverride: policy.localDiscoveryHostOverride
                )
            )
        }

        if let overlayPeer {
            targets.append(
                contentsOf: Self.discoveryTargets(
                    from: overlayPeer,
                    source: .overlayDirectory,
                    policy: policy,
                    hostOverride: nil
                )
            )
        }

        if let signalingSessionID,
           let signalingClient {
            let presence = try await signalingClient.fetchPresence(sessionID: signalingSessionID)
            guard presence.acceptingConnections else {
                return LoomConnectionPlan(targets: targets)
            }
            let remoteCandidateTargets = presence.peerCandidates
                .sorted(by: compareRemoteCandidates(_:_:))
                .compactMap {
                    Self.target(
                        from: $0,
                        requiredLocalPort: requiredLocalPort,
                        advertisement: presence.advertisement
                    )
                }
            targets.append(contentsOf: remoteCandidateTargets)
        }

        return LoomConnectionPlan(targets: targets)
    }

    public func connect(
        hello: LoomSessionHelloRequest,
        localPeer: LoomPeer? = nil,
        overlayPeer: LoomPeer? = nil,
        signalingSessionID: String? = nil,
        requiredLocalPort: UInt16? = nil
    ) async throws -> LoomAuthenticatedSession {
        let plan = try await makePlan(
            localPeer: localPeer,
            overlayPeer: overlayPeer,
            signalingSessionID: signalingSessionID,
            requiredLocalPort: requiredLocalPort
        )
        guard !plan.targets.isEmpty else {
            throw LoomError.sessionNotFound
        }

        var lastError: Error?
        for batch in connectionBatches(from: plan) {
            do {
                let resolved = try await connect(batch: batch, hello: hello)
                await recordConnectedTarget(resolved.target, session: resolved.session)
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

    private func compareRemoteCandidates(
        _ lhs: LoomRemoteCandidate,
        _ rhs: LoomRemoteCandidate
    ) -> Bool {
        let leftPriority = remoteCandidatePriority(lhs.transport)
        let rightPriority = remoteCandidatePriority(rhs.transport)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        if lhs.address != rhs.address {
            return lhs.address < rhs.address
        }
        return lhs.port < rhs.port
    }

    private func remoteCandidatePriority(_ transport: LoomTransportKind) -> Int {
        policy.preferredTransportOrder.firstIndex(of: transport) ?? Int.max
    }

    private static func target(
        from candidate: LoomRemoteCandidate,
        requiredLocalPort: UInt16? = nil,
        advertisement: LoomPeerAdvertisement? = nil
    ) -> LoomConnectionTarget? {
        guard let endpointPort = NWEndpoint.Port(rawValue: candidate.port) else {
            return nil
        }
        let host = NWEndpoint.Host(candidate.address)
        return LoomConnectionTarget(
            source: .remoteSignaling,
            transportKind: candidate.transport,
            endpoint: .hostPort(host: host, port: endpointPort),
            requiredLocalPort: candidate.transport.usesDatagramPath ? requiredLocalPort : nil,
            expectedIdentityKeyID: advertisement?.identityKeyID
        )
    }

    private static func discoveryTargets(
        from peer: LoomPeer,
        source: LoomConnectionTargetSource,
        policy: LoomDirectConnectionPolicy,
        hostOverride: String?
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
                let leftIndex = policy.preferredTransportOrder.firstIndex(of: lhs.transportKind) ?? Int.max
                let rightIndex = policy.preferredTransportOrder.firstIndex(of: rhs.transportKind) ?? Int.max
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
                    advertisedPort: transport.port,
                    hostOverride: hostOverride
                ),
                expectedIdentityKeyID: peer.advertisement.identityKeyID
            )
        }
    }

    private static func localEndpoint(
        from endpoint: NWEndpoint,
        advertisedPort: UInt16,
        hostOverride: String? = nil
    ) -> NWEndpoint {
        guard advertisedPort > 0 else {
            return endpoint
        }
        if let hostOverride,
           let port = NWEndpoint.Port(rawValue: advertisedPort) {
            return .hostPort(host: NWEndpoint.Host(hostOverride), port: port)
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
        case .remoteSignaling:
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
        case .remoteSignaling:
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
    ) async {
        guard let snapshot = await session.pathSnapshot else {
            LoomInstrumentation.record(
                LoomStepEvent(
                    rawValue: "loom.connection.connected.\(target.source.rawValue).\(target.transportKind.rawValue).unknown"
                )
            )
            return
        }
        let classifiedPath = LoomNetworkPathClassifier.classify(snapshot)
        LoomInstrumentation.record(
            LoomStepEvent(
                rawValue: "loom.connection.connected.\(target.source.rawValue).\(target.transportKind.rawValue).\(classifiedPath.kind.rawValue)"
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
