//
//  LoomStore.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

import CloudKit
import Foundation
import Loom
import LoomCloudKit
#if canImport(UIKit)
import UIKit
#endif

struct LoomStoreSnapshot: Sendable {
    let peers: [LoomPeerSnapshot]
    let connections: [LoomConnectionSnapshot]
    let transfers: [LoomTransferSnapshot]
    let isRunning: Bool
    let isRemoteHosting: Bool
    let lastErrorMessage: String?
}

private struct ManagedConnection: Sendable {
    let handle: LoomConnectionHandle
    let relaySessionID: String?
}

enum LoomStoreError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case peerNotFound(UUID)
    case relayUnavailable
    case cloudKitUnavailable
    case bootstrapMetadataUnavailable
    case wakeOnLANUnavailable
    case controlEndpointUnavailable
    case sshEndpointUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case let .peerNotFound(peerID):
            "LoomKit could not resolve peer \(peerID.uuidString)."
        case .relayUnavailable:
            "LoomKit relay configuration is unavailable."
        case .cloudKitUnavailable:
            "LoomKit CloudKit integration is unavailable."
        case .bootstrapMetadataUnavailable:
            "LoomKit peer bootstrap metadata is unavailable."
        case .wakeOnLANUnavailable:
            "The selected peer does not publish Wake-on-LAN metadata."
        case .controlEndpointUnavailable:
            "The selected peer does not publish a bootstrap control endpoint."
        case .sshEndpointUnavailable:
            "The selected peer does not publish an SSH bootstrap endpoint."
        }
    }
}

actor LoomStore {
    let configuration: LoomContainerConfiguration
    let deviceID: UUID

    private let node: LoomNode
    private let trustStore: LoomTrustStore
    private let cloudKitManager: LoomCloudKitManager?
    private let peerProvider: LoomCloudKitPeerProvider?
    private let shareManager: LoomCloudKitShareManager?
    private let relayClient: LoomRelayClient?
    private let connectionCoordinator: LoomConnectionCoordinator
    private let wakeOnLANClient: any LoomWakeOnLANClient
    private let bootstrapControlClient: any LoomBootstrapControlClient
    private let sshBootstrapClient: any LoomSSHBootstrapClient
    private let snapshotBroadcaster = LoomAsyncBroadcaster<LoomStoreSnapshot>()
    private let incomingConnectionBroadcaster = LoomAsyncBroadcaster<LoomConnectionHandle>()

    private var isRunning = false
    private var isRemoteHosting = false
    private var lastErrorMessage: String?
    private var listeningPorts: [LoomTransportKind: UInt16] = [:]
    private var discoveryObserverToken: UUID?
    private var localPeersByID: [UUID: LoomPeer] = [:]
    private var localPeerLastSeen: [UUID: Date] = [:]
    private var cloudPeersByID: [UUID: LoomCloudKitPeerInfo] = [:]
    private var connections: [UUID: ManagedConnection] = [:]
    private var connectionSnapshots: [UUID: LoomConnectionSnapshot] = [:]
    private var transferSnapshots: [UUID: LoomTransferSnapshot] = [:]
    private var relayHeartbeatTask: Task<Void, Never>?
    private var currentRemoteSessionID: String?
    private var currentPublicHostForTCP: String?

    init(
        configuration: LoomContainerConfiguration,
        deviceID: UUID,
        node: LoomNode,
        trustStore: LoomTrustStore,
        cloudKitManager: LoomCloudKitManager?,
        peerProvider: LoomCloudKitPeerProvider?,
        shareManager: LoomCloudKitShareManager?,
        relayClient: LoomRelayClient?,
        connectionCoordinator: LoomConnectionCoordinator,
        wakeOnLANClient: any LoomWakeOnLANClient = LoomDefaultWakeOnLANClient(),
        bootstrapControlClient: any LoomBootstrapControlClient = LoomDefaultBootstrapControlClient(),
        sshBootstrapClient: any LoomSSHBootstrapClient = LoomDefaultSSHBootstrapClient()
    ) {
        self.configuration = configuration
        self.deviceID = deviceID
        self.node = node
        self.trustStore = trustStore
        self.cloudKitManager = cloudKitManager
        self.peerProvider = peerProvider
        self.shareManager = shareManager
        self.relayClient = relayClient
        self.connectionCoordinator = connectionCoordinator
        self.wakeOnLANClient = wakeOnLANClient
        self.bootstrapControlClient = bootstrapControlClient
        self.sshBootstrapClient = sshBootstrapClient
    }

    func makeSnapshotStream() -> AsyncStream<LoomStoreSnapshot> {
        snapshotBroadcaster.makeStream(initialValue: currentSnapshot())
    }

    func makeIncomingConnectionsStream() -> AsyncStream<LoomConnectionHandle> {
        incomingConnectionBroadcaster.makeStream()
    }

    func start() async throws {
        guard !isRunning else {
            return
        }

        do {
            try validateConfiguration()
            lastErrorMessage = nil

            if let cloudKitManager {
                await cloudKitManager.initialize()
            }
            if let shareManager {
                await shareManager.setup()
            }

            let discovery = await MainActor.run {
                node.makeDiscovery(localDeviceID: deviceID)
            }
            let observerToken = await MainActor.run {
                discovery.addPeersChangedObserver { [weak self] peers in
                    guard let self else { return }
                    Task {
                        await self.handleLocalPeersChanged(peers)
                    }
                }
            }
            discoveryObserverToken = observerToken

            let ports = try await node.startAuthenticatedAdvertising(
                serviceName: configuration.serviceName,
                helloProvider: { [weak self] in
                    guard let self else {
                        throw LoomStoreError.invalidConfiguration("LoomKit store is unavailable.")
                    }
                    return try await self.makeHelloRequest()
                },
                onSession: { [weak self] session in
                    guard let self else { return }
                    Task {
                        await self.acceptIncomingSession(session)
                    }
                }
            )
            listeningPorts = ports
            isRunning = true

            await MainActor.run {
                discovery.startDiscovery()
            }
            await handleLocalPeersChanged(
                await MainActor.run {
                    discovery.discoveredPeers
                }
            )
            await refreshCloudPeers()
            try await publishCurrentPeer()

            if let remoteSessionID = configuration.remoteSessionID,
               relayClient != nil {
                try await startRemoteHosting(
                    sessionID: remoteSessionID,
                    publicHostForTCP: nil,
                    shouldNotify: false
                )
            }

            await notifyStateChanged()
        } catch {
            await record(error)
            await stop()
            throw error
        }
    }

    func stop() async {
        relayHeartbeatTask?.cancel()
        relayHeartbeatTask = nil

        if let currentRemoteSessionID,
           let relayClient {
            try? await relayClient.closePeerSession(sessionID: currentRemoteSessionID)
        }
        currentRemoteSessionID = nil
        currentPublicHostForTCP = nil
        isRemoteHosting = false

        let activeConnections = Array(connections.values)
        connections.removeAll()
        connectionSnapshots.removeAll()
        transferSnapshots.removeAll()

        for managedConnection in activeConnections {
            await managedConnection.handle.disconnect()
        }

        if let discoveryObserverToken,
           let discovery = await MainActor.run(body: { node.discovery }) {
            await MainActor.run {
                discovery.removePeersChangedObserver(discoveryObserverToken)
                discovery.stopDiscovery()
            }
        }
        self.discoveryObserverToken = nil

        localPeersByID.removeAll()
        localPeerLastSeen.removeAll()
        cloudPeersByID.removeAll()
        listeningPorts.removeAll()

        await node.stopAdvertising()
        isRunning = false
        await notifyStateChanged()
    }

    func refreshPeers() async {
        if let discovery = await MainActor.run(body: { node.discovery }),
           isRunning {
            await MainActor.run {
                discovery.refresh()
            }
        }
        await refreshCloudPeers()
    }

    func connect(to peerSnapshot: LoomPeerSnapshot) async throws -> LoomConnectionHandle {
        if !isRunning {
            try await start()
        }

        let resolvedPeer = currentPeerSnapshot(for: peerSnapshot.id) ?? peerSnapshot
        let localPeer = localPeersByID[resolvedPeer.id]
        let relaySessionID = localPeer == nil ? resolvedPeer.relaySessionID : nil

        guard localPeer != nil || relaySessionID != nil else {
            throw LoomStoreError.peerNotFound(resolvedPeer.id)
        }

        return try await connect(
            preferredPeer: resolvedPeer,
            localPeer: localPeer,
            relaySessionID: relaySessionID
        )
    }

    func connect(remoteSessionID: String) async throws -> LoomConnectionHandle {
        if !isRunning {
            try await start()
        }

        let sessionID = remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            throw LoomStoreError.invalidConfiguration("LoomKit remote session ID must not be empty.")
        }

        let knownPeer = currentSnapshot().peers.first { $0.relaySessionID == sessionID }
        return try await connect(
            preferredPeer: knownPeer,
            localPeer: nil,
            relaySessionID: sessionID
        )
    }

    func disconnect(connectionID: UUID) async {
        guard let managedConnection = connections[connectionID] else {
            return
        }
        await managedConnection.handle.disconnect()
    }

    func startRemoteHosting(
        sessionID: String,
        publicHostForTCP: String?
    ) async throws {
        try await startRemoteHosting(
            sessionID: sessionID,
            publicHostForTCP: publicHostForTCP,
            shouldNotify: true
        )
    }

    func stopRemoteHosting() async {
        relayHeartbeatTask?.cancel()
        relayHeartbeatTask = nil

        if let currentRemoteSessionID,
           let relayClient {
            try? await relayClient.closePeerSession(sessionID: currentRemoteSessionID)
        }

        currentRemoteSessionID = nil
        currentPublicHostForTCP = nil
        isRemoteHosting = false

        do {
            try await publishCurrentPeer()
        } catch {
            await record(error)
        }
        await notifyStateChanged()
    }

    func wake(_ peerSnapshot: LoomPeerSnapshot) async throws {
        guard let wakeOnLAN = resolveBootstrapMetadata(for: peerSnapshot)?.wakeOnLAN else {
            throw LoomStoreError.wakeOnLANUnavailable
        }
        try await wakeOnLANClient.sendMagicPacket(wakeOnLAN, retries: 2, retryDelay: .milliseconds(400))
    }

    func requestUnlock(
        _ peerSnapshot: LoomPeerSnapshot,
        username: String,
        password: String
    ) async throws -> LoomBootstrapControlResult {
        guard let bootstrapMetadata = resolveBootstrapMetadata(for: peerSnapshot) else {
            throw LoomStoreError.bootstrapMetadataUnavailable
        }

        let resolvedEndpoints = LoomBootstrapEndpointResolver.resolve(bootstrapMetadata.endpoints)
        guard let bootstrapEndpoint = resolvedEndpoints.first else {
            throw LoomStoreError.bootstrapMetadataUnavailable
        }

        if bootstrapMetadata.supportsPreloginDaemon,
           let controlPort = bootstrapMetadata.controlPort,
           let controlAuthSecret = bootstrapMetadata.controlAuthSecret {
            return try await bootstrapControlClient.requestUnlock(
                endpoint: bootstrapEndpoint,
                controlPort: controlPort,
                controlAuthSecret: controlAuthSecret,
                username: username,
                password: password,
                timeout: .seconds(20)
            )
        }

        guard let sshPort = bootstrapMetadata.sshPort else {
            throw LoomStoreError.controlEndpointUnavailable
        }
        guard let sshHostKeyFingerprint = bootstrapMetadata.sshHostKeyFingerprint else {
            throw LoomStoreError.sshEndpointUnavailable
        }

        let sshEndpoint = LoomBootstrapEndpoint(
            host: bootstrapEndpoint.host,
            port: sshPort,
            source: bootstrapEndpoint.source
        )
        let sshResult = try await sshBootstrapClient.unlockVolumeOverSSH(
            endpoint: sshEndpoint,
            username: username,
            password: password,
            expectedHostKeyFingerprint: sshHostKeyFingerprint,
            timeout: .seconds(20)
        )
        return LoomBootstrapControlResult(
            state: sshResult.unlocked ? .ready : .unavailable,
            message: sshResult.unlocked ? "SSH bootstrap completed." : "SSH bootstrap did not report a ready session."
        )
    }

    func createShare() async throws -> CKShare {
        guard let shareManager else {
            throw LoomStoreError.cloudKitUnavailable
        }
        return try await shareManager.createShare()
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws {
        guard let shareManager else {
            throw LoomStoreError.cloudKitUnavailable
        }
        try await shareManager.acceptShare(metadata)
        await refreshCloudPeers()
    }

    func updateConnectionState(
        id: UUID,
        state: LoomConnectionSnapshot.State,
        lastError: String?
    ) async {
        guard let existingSnapshot = connectionSnapshots[id] else {
            return
        }
        connectionSnapshots[id] = LoomConnectionSnapshot(
            id: existingSnapshot.id,
            peerID: existingSnapshot.peerID,
            peerName: existingSnapshot.peerName,
            state: state,
            transportKind: existingSnapshot.transportKind,
            connectedAt: existingSnapshot.connectedAt,
            lastError: lastError
        )
        await notifyStateChanged()
    }

    func updateTransferSnapshot(_ snapshot: LoomTransferSnapshot) async {
        transferSnapshots[snapshot.id] = snapshot
        await notifyStateChanged()
    }

    func handleConnectionDisconnected(
        id: UUID,
        errorMessage: String?
    ) async {
        if let relaySessionID = connections[id]?.relaySessionID,
           let relayClient {
            try? await relayClient.leaveSession(sessionID: relaySessionID)
        }

        connections.removeValue(forKey: id)
        if let existingSnapshot = connectionSnapshots[id] {
            connectionSnapshots[id] = LoomConnectionSnapshot(
                id: existingSnapshot.id,
                peerID: existingSnapshot.peerID,
                peerName: existingSnapshot.peerName,
                state: errorMessage == nil ? .disconnected : .failed,
                transportKind: existingSnapshot.transportKind,
                connectedAt: existingSnapshot.connectedAt,
                lastError: errorMessage
            )
            connectionSnapshots.removeValue(forKey: id)
        }
        transferSnapshots = transferSnapshots.filter { $0.value.connectionID != id }
        await notifyStateChanged()
    }

    private func startRemoteHosting(
        sessionID: String,
        publicHostForTCP: String?,
        shouldNotify: Bool
    ) async throws {
        guard let relayClient else {
            throw LoomStoreError.relayUnavailable
        }
        if !isRunning {
            try await start()
        }

        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else {
            throw LoomStoreError.invalidConfiguration("LoomKit remote session ID must not be empty.")
        }

        let peerCandidates = await LoomDirectCandidateCollector.collect(
            configuration: await MainActor.run { node.configuration },
            listeningPorts: listeningPorts,
            publicHostForTCP: publicHostForTCP
        )
        try await relayClient.advertisePeerSession(
            sessionID: trimmedSessionID,
            peerID: deviceID,
            acceptingConnections: true,
            peerCandidates: peerCandidates
        )

        currentRemoteSessionID = trimmedSessionID
        currentPublicHostForTCP = publicHostForTCP
        isRemoteHosting = true

        relayHeartbeatTask?.cancel()
        relayHeartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.runRelayHeartbeat(sessionID: trimmedSessionID)
        }

        try await publishCurrentPeer()
        if shouldNotify {
            await notifyStateChanged()
        }
    }

    private func runRelayHeartbeat(sessionID: String) async {
        while !Task.isCancelled {
            do {
                guard let relayClient else {
                    return
                }
                let peerCandidates = await LoomDirectCandidateCollector.collect(
                    configuration: await MainActor.run { node.configuration },
                    listeningPorts: listeningPorts,
                    publicHostForTCP: currentPublicHostForTCP
                )
                try await relayClient.peerHeartbeat(
                    sessionID: sessionID,
                    acceptingConnections: true,
                    peerCandidates: peerCandidates,
                    ttlSeconds: 360
                )
                if let shareManager {
                    await shareManager.updateLastSeen()
                }
            } catch let relayError as LoomRelayError {
                await record(relayError)
                if relayError.isPermanentConfigurationFailure {
                    await stopRemoteHosting()
                    return
                }
            } catch {
                await record(error)
            }

            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func publishCurrentPeer() async throws {
        guard let shareManager,
              let cloudKitManager else {
            return
        }
        let isCloudKitAvailable = await MainActor.run {
            cloudKitManager.isAvailable
        }
        guard isCloudKitAvailable else {
            return
        }

        let advertisement = try await makeAdvertisement()
        let identity = try await MainActor.run {
            try (node.identityManager ?? LoomIdentityManager.shared).currentIdentity()
        }
        try await shareManager.registerPeer(
            deviceID: deviceID,
            name: configuration.serviceName,
            advertisement: advertisement,
            identityPublicKey: identity.publicKey,
            remoteAccessEnabled: isRemoteHosting,
            relaySessionID: currentRemoteSessionID,
            bootstrapMetadata: try await loadBootstrapMetadata()
        )
        await refreshCloudPeers()
    }

    private func refreshCloudPeers() async {
        guard let peerProvider,
              let cloudKitManager else {
            cloudPeersByID.removeAll()
            await notifyStateChanged()
            return
        }
        let isCloudKitAvailable = await MainActor.run {
            cloudKitManager.isAvailable
        }
        guard isCloudKitAvailable else {
            cloudPeersByID.removeAll()
            await notifyStateChanged()
            return
        }

        await peerProvider.fetchPeers()
        let cloudPeers = await MainActor.run {
            return (peerProvider.ownPeers + peerProvider.sharedPeers)
                .filter { $0.id != deviceID }
        }
        cloudPeersByID = Dictionary(
            uniqueKeysWithValues: cloudPeers.map { ($0.id, $0) }
        )
        await notifyStateChanged()
    }

    private func handleLocalPeersChanged(_ peers: [LoomPeer]) async {
        let now = Date()
        localPeersByID = Dictionary(
            uniqueKeysWithValues: peers
                .filter { $0.id != deviceID }
                .map { ($0.id, $0) }
        )
        localPeerLastSeen = Dictionary(
            uniqueKeysWithValues: localPeersByID.keys.map { ($0, now) }
        )
        await notifyStateChanged()
    }

    private func acceptIncomingSession(_ session: LoomAuthenticatedSession) async {
        do {
            let peerSnapshot = try await resolveConnectedPeer(
                preferredPeer: nil,
                session: session,
                relaySessionID: nil
            )
            let handle = await registerConnection(
                session: session,
                peerSnapshot: peerSnapshot,
                relaySessionID: nil
            )
            incomingConnectionBroadcaster.yield(handle)
            await notifyStateChanged()
        } catch {
            await record(error)
            await session.cancel()
        }
    }

    private func connect(
        preferredPeer: LoomPeerSnapshot?,
        localPeer: LoomPeer?,
        relaySessionID: String?
    ) async throws -> LoomConnectionHandle {
        let hello = try await makeHelloRequest()
        var didJoinRelay = false

        if let relaySessionID,
           localPeer == nil {
            guard let relayClient else {
                throw LoomStoreError.relayUnavailable
            }
            try await relayClient.joinSession(sessionID: relaySessionID)
            didJoinRelay = true
        }

        do {
            let session = try await connectionCoordinator.connect(
                hello: hello,
                localPeer: localPeer,
                relaySessionID: relaySessionID
            )
            let peerSnapshot = try await resolveConnectedPeer(
                preferredPeer: preferredPeer,
                session: session,
                relaySessionID: didJoinRelay ? relaySessionID : nil
            )
            return await registerConnection(
                session: session,
                peerSnapshot: peerSnapshot,
                relaySessionID: didJoinRelay ? relaySessionID : nil
            )
        } catch {
            if didJoinRelay,
               let relaySessionID,
               let relayClient {
                try? await relayClient.leaveSession(sessionID: relaySessionID)
            }
            await record(error)
            throw error
        }
    }

    private func registerConnection(
        session: LoomAuthenticatedSession,
        peerSnapshot: LoomPeerSnapshot,
        relaySessionID: String?
    ) async -> LoomConnectionHandle {
        let connectionID = UUID()
        let handle = LoomConnectionHandle(
            id: connectionID,
            peer: peerSnapshot,
            session: session,
            transferConfiguration: configuration.transferConfiguration,
            onStateChanged: { [weak self] id, state, lastError in
                guard let self else { return }
                await self.updateConnectionState(id: id, state: state, lastError: lastError)
            },
            onTransferChanged: { [weak self] snapshot in
                guard let self else { return }
                await self.updateTransferSnapshot(snapshot)
            },
            onDisconnected: { [weak self] id, errorMessage in
                guard let self else { return }
                await self.handleConnectionDisconnected(id: id, errorMessage: errorMessage)
            }
        )
        connections[connectionID] = ManagedConnection(
            handle: handle,
            relaySessionID: relaySessionID
        )
        connectionSnapshots[connectionID] = LoomConnectionSnapshot(
            id: connectionID,
            peerID: peerSnapshot.id,
            peerName: peerSnapshot.name,
            state: .connected,
            transportKind: await session.transportKind,
            connectedAt: Date()
        )
        await handle.startObservers()
        return handle
    }

    private func resolveConnectedPeer(
        preferredPeer: LoomPeerSnapshot?,
        session: LoomAuthenticatedSession,
        relaySessionID: String?
    ) async throws -> LoomPeerSnapshot {
        if let preferredPeer {
            return preferredPeer
        }
        guard let sessionContext = await session.context else {
            throw LoomStoreError.invalidConfiguration("LoomKit connected without authenticated session context.")
        }
        if let currentPeerSnapshot = currentPeerSnapshot(for: sessionContext.peerIdentity.deviceID) {
            return currentPeerSnapshot
        }

        return LoomPeerSnapshot(
            id: sessionContext.peerIdentity.deviceID,
            name: sessionContext.peerIdentity.name,
            deviceType: sessionContext.peerIdentity.deviceType,
            sources: relaySessionID == nil ? [] : [.relay],
            isNearby: false,
            isShared: false,
            remoteAccessEnabled: relaySessionID != nil,
            relaySessionID: relaySessionID,
            advertisement: LoomPeerAdvertisement(
                deviceID: sessionContext.peerIdentity.deviceID,
                identityKeyID: sessionContext.peerIdentity.identityKeyID,
                deviceType: sessionContext.peerIdentity.deviceType
            ),
            bootstrapMetadata: nil,
            lastSeen: Date()
        )
    }

    private func makeHelloRequest() async throws -> LoomSessionHelloRequest {
        let profile = await makeDeviceProfile()
        let identityKeyID = try await MainActor.run {
            try (node.identityManager ?? LoomIdentityManager.shared).currentIdentity().keyID
        }
        let bootstrapMetadata = try await loadBootstrapMetadata()

        return try profile.makeHelloRequest(
            identityKeyID: identityKeyID,
            directTransports: currentDirectTransports()
        ) { metadata in
            try LoomKitMetadataCodec.addingBootstrapMetadata(
                bootstrapMetadata,
                to: metadata
            )
        }
    }

    private func makeAdvertisement() async throws -> LoomPeerAdvertisement {
        let profile = await makeDeviceProfile()
        let identityKeyID = try await MainActor.run {
            try (node.identityManager ?? LoomIdentityManager.shared).currentIdentity().keyID
        }
        let bootstrapMetadata = try await loadBootstrapMetadata()

        return try profile.makeAdvertisement(
            identityKeyID: identityKeyID,
            directTransports: currentDirectTransports()
        ) { metadata in
            try LoomKitMetadataCodec.addingBootstrapMetadata(
                bootstrapMetadata,
                to: metadata
            )
        }
    }

    private func makeDeviceProfile() async -> LoomDeviceProfile {
        LoomDeviceProfile(
            deviceID: deviceID,
            deviceName: configuration.serviceName,
            deviceType: Self.currentDeviceType(),
            iCloudUserID: await MainActor.run {
                cloudKitManager?.currentUserRecordID
            },
            additionalAdvertisementMetadata: configuration.advertisementMetadata,
            additionalSupportedFeatures: configuration.supportedFeatures
        )
    }

    private func loadBootstrapMetadata() async throws -> LoomBootstrapMetadata? {
        try await configuration.bootstrapMetadataProvider?()
    }

    private func currentDirectTransports() -> [LoomDirectTransportAdvertisement] {
        listeningPorts.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { transportKind in
            guard let port = listeningPorts[transportKind],
                  port > 0 else {
                return nil
            }
            return LoomDirectTransportAdvertisement(
                transportKind: transportKind,
                port: port
            )
        }
    }

    private func currentSnapshot() -> LoomStoreSnapshot {
        LoomStoreSnapshot(
            peers: mergedPeers(),
            connections: connectionSnapshots.values.sorted { lhs, rhs in
                if lhs.connectedAt != rhs.connectedAt {
                    return lhs.connectedAt > rhs.connectedAt
                }
                return lhs.peerName < rhs.peerName
            },
            transfers: transferSnapshots.values.sorted { lhs, rhs in
                if lhs.logicalName != rhs.logicalName {
                    return lhs.logicalName < rhs.logicalName
                }
                return lhs.id.uuidString < rhs.id.uuidString
            },
            isRunning: isRunning,
            isRemoteHosting: isRemoteHosting,
            lastErrorMessage: lastErrorMessage
        )
    }

    private func mergedPeers() -> [LoomPeerSnapshot] {
        let peerIDs = Set(localPeersByID.keys).union(cloudPeersByID.keys)
        return peerIDs.compactMap(currentPeerSnapshot(for:)).sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func currentPeerSnapshot(for peerID: UUID) -> LoomPeerSnapshot? {
        let localPeer = localPeersByID[peerID]
        let cloudPeer = cloudPeersByID[peerID]
        guard localPeer != nil || cloudPeer != nil else {
            return nil
        }

        let deviceType = localPeer?.deviceType ?? cloudPeer?.deviceType ?? .unknown
        let advertisement = localPeer?.advertisement
            ?? cloudPeer?.advertisement
            ?? LoomPeerAdvertisement(deviceID: peerID, deviceType: deviceType)
        let bootstrapMetadata = LoomKitMetadataCodec.bootstrapMetadata(from: advertisement)
            ?? cloudPeer?.bootstrapMetadata
        var sources: [LoomPeerSource] = []
        if localPeer != nil {
            sources.append(.nearby)
        }
        if let cloudPeer {
            sources.append(cloudPeer.isShared ? .cloudKitShared : .cloudKitOwn)
            if cloudPeer.relaySessionID != nil {
                sources.append(.relay)
            }
        }

        let localLastSeen = localPeerLastSeen[peerID] ?? .distantPast
        let cloudLastSeen = cloudPeer?.lastSeen ?? .distantPast
        let lastSeen = max(localLastSeen, cloudLastSeen)
        let name = resolvedPeerName(localPeer: localPeer, cloudPeer: cloudPeer)

        return LoomPeerSnapshot(
            id: peerID,
            name: name,
            deviceType: deviceType,
            sources: sources,
            isNearby: localPeer != nil,
            isShared: cloudPeer?.isShared ?? false,
            remoteAccessEnabled: cloudPeer?.remoteAccessEnabled ?? false,
            relaySessionID: cloudPeer?.relaySessionID,
            advertisement: advertisement,
            bootstrapMetadata: bootstrapMetadata,
            lastSeen: lastSeen
        )
    }

    private func resolveBootstrapMetadata(for peerSnapshot: LoomPeerSnapshot) -> LoomBootstrapMetadata? {
        currentPeerSnapshot(for: peerSnapshot.id)?.bootstrapMetadata ?? peerSnapshot.bootstrapMetadata
    }

    private func resolvedPeerName(
        localPeer: LoomPeer?,
        cloudPeer: LoomCloudKitPeerInfo?
    ) -> String {
        if let localPeer,
           localPeer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return localPeer.name
        }
        if let cloudPeer,
           cloudPeer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return cloudPeer.name
        }
        return "Unknown Peer"
    }

    private func notifyStateChanged() async {
        snapshotBroadcaster.yield(currentSnapshot())
    }

    private func record(_ error: Error) async {
        lastErrorMessage = error.localizedDescription
        await notifyStateChanged()
    }

    private func validateConfiguration() throws {
        if configuration.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LoomStoreError.invalidConfiguration("LoomKit service type must not be empty.")
        }
        if configuration.serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LoomStoreError.invalidConfiguration("LoomKit service name must not be empty.")
        }
    }

    private static func currentDeviceType() -> DeviceType {
        #if os(macOS)
        .mac
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #elseif os(visionOS)
        .vision
        #else
        .unknown
        #endif
    }
}
