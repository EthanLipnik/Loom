//
//  LoomHostRuntime.swift
//  LoomHost
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CloudKit
import Foundation
import Loom
import LoomCloudKit
#if canImport(UIKit)
import UIKit
#endif

package struct LoomHostRuntimeDependencies: Sendable {
    package enum StartupMode: Sendable {
        case liveNetworking
        case simulated
    }

    package let serviceName: String
    package let deviceID: UUID
    package let node: LoomNode
    package let cloudKitManager: LoomCloudKitManager?
    package let peerProvider: LoomCloudKitPeerProvider?
    package let peerManager: LoomCloudKitPeerManager?
    package let signalingClient: LoomRemoteSignalingClient?
    package let overlayDirectoryConfiguration: LoomOverlayDirectoryConfiguration?
    package let connectionCoordinator: LoomConnectionCoordinator
    package let bootstrapMetadataProvider: (@Sendable () async throws -> LoomBootstrapMetadata?)?
    package let hostAdvertisementMetadata: [String: String]
    package let hostSupportedFeatures: [String]
    package let startupMode: StartupMode

    package init(
        serviceName: String,
        deviceID: UUID,
        node: LoomNode,
        cloudKitManager: LoomCloudKitManager?,
        peerProvider: LoomCloudKitPeerProvider?,
        peerManager: LoomCloudKitPeerManager?,
        signalingClient: LoomRemoteSignalingClient?,
        overlayDirectoryConfiguration: LoomOverlayDirectoryConfiguration?,
        connectionCoordinator: LoomConnectionCoordinator,
        bootstrapMetadataProvider: (@Sendable () async throws -> LoomBootstrapMetadata?)?,
        hostAdvertisementMetadata: [String: String],
        hostSupportedFeatures: [String],
        startupMode: StartupMode = .liveNetworking
    ) {
        self.serviceName = serviceName
        self.deviceID = deviceID
        self.node = node
        self.cloudKitManager = cloudKitManager
        self.peerProvider = peerProvider
        self.peerManager = peerManager
        self.signalingClient = signalingClient
        self.overlayDirectoryConfiguration = overlayDirectoryConfiguration
        self.connectionCoordinator = connectionCoordinator
        self.bootstrapMetadataProvider = bootstrapMetadataProvider
        self.hostAdvertisementMetadata = hostAdvertisementMetadata
        self.hostSupportedFeatures = hostSupportedFeatures
        self.startupMode = startupMode
    }
}

package struct LoomHostEstablishedSession: Sendable {
    package let peer: LoomHostPeerRecord
    package let session: LoomAuthenticatedSession
}

/// Identifies one broker-ordered claim on an app ID. App IDs are stable across process launches,
/// so teardown must match this generation before it can remove the runtime's current claim.
package struct LoomHostRuntimeAppRegistration: Sendable, Hashable {
    package let appID: String
    package let generation: UInt64

    package init(appID: String, generation: UInt64) {
        self.appID = appID
        self.generation = generation
    }
}

private struct LoomHostRuntimeRegisteredApp {
    let descriptor: LoomHostAppDescriptor
    let registration: LoomHostRuntimeAppRegistration
}

package actor LoomHostRuntime {
    private let dependencies: LoomHostRuntimeDependencies
    private let onStateChanged: @Sendable (LoomHostStateSnapshot) async -> Void
    private let onIncomingSession: @Sendable (LoomAuthenticatedSession) async -> Void

    private var isRunning = false
    private var isRemoteHosting = false
    private var lastErrorMessage: String?
    private var listeningPorts: [LoomTransportKind: UInt16] = [:]
    private var discoveryObserverToken: UUID?
    private var overlayDirectory: LoomOverlayDirectory?
    private var overlayDirectoryObserverToken: UUID?
    private var localPeersByID: [LoomPeerID: LoomPeer] = [:]
    private var localPeerLastSeen: [LoomPeerID: Date] = [:]
    private var overlayPeersByID: [LoomPeerID: LoomPeer] = [:]
    private var overlayPeerLastSeen: [LoomPeerID: Date] = [:]
    private var cloudPeersByID: [LoomPeerID: LoomCloudKitPeerInfo] = [:]
    private var signalingHeartbeatTask: Task<Void, Never>?
    private var currentRemoteSessionID: String?
    private var currentPublicHostForTCP: String?
    private var registeredApps: [String: LoomHostRuntimeRegisteredApp] = [:]

    package init(
        dependencies: LoomHostRuntimeDependencies,
        onStateChanged: @escaping @Sendable (LoomHostStateSnapshot) async -> Void,
        onIncomingSession: @escaping @Sendable (LoomAuthenticatedSession) async -> Void
    ) {
        self.dependencies = dependencies
        self.onStateChanged = onStateChanged
        self.onIncomingSession = onIncomingSession
    }

    package func register(
        app: LoomHostAppDescriptor,
        registration: LoomHostRuntimeAppRegistration
    ) async throws -> Bool {
        guard registration.appID == app.appID else {
            throw LoomHostError.protocolViolation("Shared-host app registration identity mismatch.")
        }
        if let current = registeredApps[app.appID],
           current.registration.generation > registration.generation {
            return false
        }
        registeredApps[app.appID] = LoomHostRuntimeRegisteredApp(
            descriptor: app,
            registration: registration
        )
        if isRunning {
            try await republishHostStateIfNeeded()
            await notifyStateChanged()
            return registeredApps[app.appID]?.registration == registration
        }
        try await startIfNeeded()
        return registeredApps[app.appID]?.registration == registration
    }

    package func unregister(registration: LoomHostRuntimeAppRegistration) async {
        guard registeredApps[registration.appID]?.registration == registration else {
            return
        }
        registeredApps.removeValue(forKey: registration.appID)
        if registeredApps.isEmpty {
            await stop()
            return
        }
        try? await republishHostStateIfNeeded()
        await notifyStateChanged()
    }

    package func startIfNeeded() async throws {
        guard !isRunning else {
            return
        }
        guard !registeredApps.isEmpty else {
            throw LoomHostError.protocolViolation("Cannot start shared-host runtime without any registered apps.")
        }
        if dependencies.startupMode == .simulated {
            lastErrorMessage = nil
            isRunning = true
            await notifyStateChanged()
            return
        }

        do {
            lastErrorMessage = nil

            if let cloudKitManager = dependencies.cloudKitManager {
                await cloudKitManager.initialize()
            }
            if let peerManager = dependencies.peerManager {
                await peerManager.setup()
            }

            let discovery = await MainActor.run {
                dependencies.node.makeDiscovery(localDeviceID: dependencies.deviceID)
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

            if let overlayDirectoryConfiguration = dependencies.overlayDirectoryConfiguration {
                if overlayDirectory == nil {
                    overlayDirectory = await MainActor.run {
                        LoomOverlayDirectory(
                            configuration: overlayDirectoryConfiguration,
                            localDeviceID: dependencies.deviceID
                        )
                    }
                }
                if let overlayDirectory {
                    let token = await MainActor.run {
                        overlayDirectory.addPeersChangedObserver { [weak self] peers in
                            guard let self else { return }
                            Task {
                                await self.handleOverlayPeersChanged(peers)
                            }
                        }
                    }
                    overlayDirectoryObserverToken = token
                }
            }

            let ports = try await dependencies.node.startAuthenticatedAdvertising(
                serviceName: dependencies.serviceName,
                helloProvider: { [weak self] in
                    guard let self else {
                        throw LoomHostError.protocolViolation("Shared-host runtime is unavailable.")
                    }
                    return try await self.makeHelloRequest(
                        targetAppID: nil,
                        sourceAppID: nil
                    )
                },
                onSession: { [weak self] session in
                    guard let self else { return }
                    Task {
                        await self.onIncomingSession(session)
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
            if let overlayDirectory {
                await MainActor.run {
                    overlayDirectory.start()
                }
                await overlayDirectory.refresh()
                await handleOverlayPeersChanged(
                    await MainActor.run {
                        overlayDirectory.discoveredPeers
                    }
                )
            }
            await refreshCloudPeers()
            try await publishCurrentPeer()
            await notifyStateChanged()
        } catch {
            await record(error)
            await stop()
            throw error
        }
    }

    package func stop() async {
        signalingHeartbeatTask?.cancel()
        signalingHeartbeatTask = nil

        if let currentRemoteSessionID,
           let signalingClient = dependencies.signalingClient {
            try? await signalingClient.closePeerSession(sessionID: currentRemoteSessionID)
        }
        currentRemoteSessionID = nil
        currentPublicHostForTCP = nil
        isRemoteHosting = false

        if let discoveryObserverToken,
           let discovery = await MainActor.run(body: { dependencies.node.discovery }) {
            await MainActor.run {
                discovery.removePeersChangedObserver(discoveryObserverToken)
                discovery.stopDiscovery()
            }
        }
        self.discoveryObserverToken = nil
        if let overlayDirectoryObserverToken,
           let overlayDirectory {
            await MainActor.run {
                overlayDirectory.removePeersChangedObserver(overlayDirectoryObserverToken)
                overlayDirectory.stop()
            }
        }
        self.overlayDirectoryObserverToken = nil

        localPeersByID.removeAll()
        localPeerLastSeen.removeAll()
        overlayPeersByID.removeAll()
        overlayPeerLastSeen.removeAll()
        cloudPeersByID.removeAll()
        listeningPorts.removeAll()

        await dependencies.node.stopAdvertising()
        isRunning = false
        await notifyStateChanged()
    }

    package func refreshPeers() async {
        if let discovery = await MainActor.run(body: { dependencies.node.discovery }),
           isRunning {
            await MainActor.run {
                discovery.refresh()
            }
        }
        if let overlayDirectory,
           isRunning {
            await overlayDirectory.refresh()
        }
        await refreshCloudPeers()
    }

    package func startRemoteHosting(
        sessionID: String,
        publicHostForTCP: String?
    ) async throws {
        guard let signalingClient = dependencies.signalingClient else {
            throw LoomHostError.remoteFailure("The shared-host remote signaling configuration is unavailable.")
        }
        if !isRunning {
            try await startIfNeeded()
        }

        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else {
            throw LoomHostError.protocolViolation("Shared-host remote session ID must not be empty.")
        }

        let peerCandidates = await LoomDirectCandidateCollector.collect(
            configuration: await MainActor.run { dependencies.node.configuration },
            listeningPorts: listeningPorts,
            publicHostForTCP: publicHostForTCP
        )
        let advertisement = try await makeAdvertisement()
        try await signalingClient.advertisePeerSession(
            sessionID: trimmedSessionID,
            peerID: dependencies.deviceID,
            acceptingConnections: true,
            peerCandidates: peerCandidates,
            advertisement: advertisement
        )

        currentRemoteSessionID = trimmedSessionID
        currentPublicHostForTCP = publicHostForTCP
        isRemoteHosting = true

        signalingHeartbeatTask?.cancel()
        signalingHeartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.runSignalingHeartbeat(sessionID: trimmedSessionID)
        }

        try await publishCurrentPeer()
        await notifyStateChanged()
    }

    package func stopRemoteHosting() async {
        signalingHeartbeatTask?.cancel()
        signalingHeartbeatTask = nil

        if let currentRemoteSessionID,
           let signalingClient = dependencies.signalingClient {
            try? await signalingClient.closePeerSession(sessionID: currentRemoteSessionID)
        }

        currentRemoteSessionID = nil
        currentPublicHostForTCP = nil
        isRemoteHosting = false

        try? await publishCurrentPeer()
        await notifyStateChanged()
    }

    package func stateSnapshot() -> LoomHostStateSnapshot {
        currentSnapshot()
    }

    package func connect(
        to peerID: LoomPeerID,
        sourceAppID: String?
    ) async throws -> LoomHostEstablishedSession {
        if !isRunning {
            try await startIfNeeded()
        }

        let resolvedPeer = currentPeerRecord(for: peerID)
        let localPeer = localPeersByID[peerID]
        let overlayPeer = localPeer == nil ? overlayPeersByID[peerID] : nil
        let signalingSessionID = LoomConnectionCoordinator.signalingFallbackSessionID(
            advertisedSignalingSessionID: resolvedPeer?.signalingSessionID,
            localPeer: localPeer
        )

        guard localPeer != nil || overlayPeer != nil || signalingSessionID != nil else {
            throw LoomHostError.peerNotFound(peerID)
        }

        let hello = try await makeHelloRequest(
            targetAppID: peerID.appID,
            sourceAppID: sourceAppID
        )
        let session = try await dependencies.connectionCoordinator.connect(
            hello: hello,
            localPeer: localPeer,
            signalingSessionID: signalingSessionID
        )
        let peer = try await resolveConnectedPeer(
            preferredPeer: resolvedPeer,
            session: session,
            signalingSessionID: signalingSessionID
        )
        return LoomHostEstablishedSession(peer: peer, session: session)
    }

    package func connect(
        remoteSessionID: String,
        sourceAppID: String?
    ) async throws -> LoomHostEstablishedSession {
        if !isRunning {
            try await startIfNeeded()
        }
        let trimmedSessionID = remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else {
            throw LoomHostError.protocolViolation("Shared-host remote session ID must not be empty.")
        }

        if let signalingClient = dependencies.signalingClient {
            try await signalingClient.joinSession(sessionID: trimmedSessionID)
        }

        do {
            let hello = try await makeHelloRequest(
                targetAppID: nil,
                sourceAppID: sourceAppID
            )
            let session = try await dependencies.connectionCoordinator.connect(
                hello: hello,
                localPeer: nil,
                signalingSessionID: trimmedSessionID
            )
            let peer = try await resolveConnectedPeer(
                preferredPeer: nil,
                session: session,
                signalingSessionID: trimmedSessionID
            )
            return LoomHostEstablishedSession(peer: peer, session: session)
        } catch {
            if let signalingClient = dependencies.signalingClient {
                try? await signalingClient.leaveSession(sessionID: trimmedSessionID)
            }
            throw error
        }
    }

    package func describeIncomingSession(
        _ session: LoomAuthenticatedSession
    ) async throws -> LoomHostPeerRecord {
        try await resolveConnectedPeer(
            preferredPeer: nil,
            session: session,
            signalingSessionID: nil
        )
    }

    private func republishHostStateIfNeeded() async throws {
        guard isRunning else {
            return
        }
        let advertisement = try await makeAdvertisement()
        await dependencies.node.updateAdvertisement(advertisement)
        try await publishCurrentPeer()
        if let currentRemoteSessionID,
           let signalingClient = dependencies.signalingClient {
            let peerCandidates = await LoomDirectCandidateCollector.collect(
                configuration: await MainActor.run { dependencies.node.configuration },
                listeningPorts: listeningPorts,
                publicHostForTCP: currentPublicHostForTCP
            )
            try await signalingClient.peerHeartbeat(
                sessionID: currentRemoteSessionID,
                acceptingConnections: true,
                peerCandidates: peerCandidates,
                advertisement: advertisement,
                ttlSeconds: 360
            )
        }
    }

    private func runSignalingHeartbeat(sessionID: String) async {
        while !Task.isCancelled {
            do {
                guard let signalingClient = dependencies.signalingClient else {
                    return
                }
                let peerCandidates = await LoomDirectCandidateCollector.collect(
                    configuration: await MainActor.run { dependencies.node.configuration },
                    listeningPorts: listeningPorts,
                    publicHostForTCP: currentPublicHostForTCP
                )
                let advertisement = try await makeAdvertisement()
                try await signalingClient.peerHeartbeat(
                    sessionID: sessionID,
                    acceptingConnections: true,
                    peerCandidates: peerCandidates,
                    advertisement: advertisement,
                    ttlSeconds: 360
                )
                if let peerManager = dependencies.peerManager {
                    await peerManager.updateLastSeen()
                }
            } catch let signalingError as LoomRemoteSignalingError {
                await record(signalingError)
                if signalingError.isPermanentConfigurationFailure {
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
        guard let peerManager = dependencies.peerManager,
              let cloudKitManager = dependencies.cloudKitManager else {
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
            try (dependencies.node.identityManager ?? LoomIdentityManager.shared).currentIdentity()
        }
        try await peerManager.registerPeer(
            deviceID: dependencies.deviceID,
            name: dependencies.serviceName,
            advertisement: advertisement,
            identityPublicKey: identity.publicKey,
            remoteAccessEnabled: isRemoteHosting,
            signalingSessionID: currentRemoteSessionID,
            bootstrapMetadata: try await loadBootstrapMetadata()
        )
        await refreshCloudPeers()
    }

    private func refreshCloudPeers() async {
        guard let peerProvider = dependencies.peerProvider,
              let cloudKitManager = dependencies.cloudKitManager else {
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
            peerProvider.ownPeers.filter { $0.deviceID != dependencies.deviceID }
        }
        cloudPeersByID = Dictionary(uniqueKeysWithValues: cloudPeers.map { ($0.id, $0) })
        await notifyStateChanged()
    }

    private func handleLocalPeersChanged(_ peers: [LoomPeer]) async {
        let now = Date()
        localPeersByID = Dictionary(
            uniqueKeysWithValues: peers
                .filter { $0.deviceID != dependencies.deviceID }
                .map { ($0.id, $0) }
        )
        localPeerLastSeen = Dictionary(
            uniqueKeysWithValues: localPeersByID.keys.map { ($0, now) }
        )
        await notifyStateChanged()
    }

    private func handleOverlayPeersChanged(_ peers: [LoomPeer]) async {
        let now = Date()
        overlayPeersByID = Dictionary(
            uniqueKeysWithValues: peers
                .filter { $0.deviceID != dependencies.deviceID }
                .map { ($0.id, $0) }
        )
        overlayPeerLastSeen = Dictionary(
            uniqueKeysWithValues: overlayPeersByID.keys.map { ($0, now) }
        )
        await notifyStateChanged()
    }

    private func currentSnapshot() -> LoomHostStateSnapshot {
        LoomHostStateSnapshot(
            peers: mergedPeers(),
            isRunning: isRunning,
            isRemoteHosting: isRemoteHosting,
            lastErrorMessage: lastErrorMessage
        )
    }

    private func mergedPeers() -> [LoomHostPeerRecord] {
        let peerIDs = Set(localPeersByID.keys)
            .union(overlayPeersByID.keys)
            .union(cloudPeersByID.keys)
        return peerIDs.compactMap(currentPeerRecord(for:)).sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private func currentPeerRecord(for peerID: LoomPeerID) -> LoomHostPeerRecord? {
        let localPeer = localPeersByID[peerID]
        let overlayPeer = overlayPeersByID[peerID]
        let cloudPeer = cloudPeersByID[peerID]
        guard localPeer != nil || overlayPeer != nil || cloudPeer != nil else {
            return nil
        }

        let deviceType = localPeer?.deviceType ?? overlayPeer?.deviceType ?? cloudPeer?.deviceType ?? .unknown
        let advertisement = localPeer?.advertisement
            ?? overlayPeer?.advertisement
            ?? cloudPeer?.advertisement
            ?? LoomPeerAdvertisement(deviceID: peerID.deviceID, deviceType: deviceType)
        let bootstrapMetadata = LoomHostMetadata(
            advertisement: advertisement,
            cloudPeer: cloudPeer
        ).bootstrapMetadata

        var sources: [LoomHostPeerSource] = []
        if localPeer != nil {
            sources.append(.nearby)
        }
        if overlayPeer != nil {
            sources.append(.overlay)
        }
        if let cloudPeer {
            sources.append(.cloudKitOwn)
            if cloudPeer.signalingSessionID != nil {
                sources.append(.remoteSignaling)
            }
        }

        let localLastSeen = localPeerLastSeen[peerID] ?? .distantPast
        let overlayLastSeen = overlayPeerLastSeen[peerID] ?? .distantPast
        let cloudLastSeen = cloudPeer?.lastSeen ?? .distantPast
        let lastSeen = max(localLastSeen, max(overlayLastSeen, cloudLastSeen))

        return LoomHostPeerRecord(
            id: peerID,
            name: resolvedPeerName(
                localPeer: localPeer,
                overlayPeer: overlayPeer,
                cloudPeer: cloudPeer
            ),
            deviceType: deviceType,
            sources: sources,
            isNearby: localPeer != nil,
            remoteAccessEnabled: cloudPeer?.remoteAccessEnabled ?? false,
            signalingSessionID: cloudPeer?.signalingSessionID,
            advertisement: advertisement,
            bootstrapMetadata: bootstrapMetadata,
            lastSeen: lastSeen
        )
    }

    private func resolveConnectedPeer(
        preferredPeer: LoomHostPeerRecord?,
        session: LoomAuthenticatedSession,
        signalingSessionID: String?
    ) async throws -> LoomHostPeerRecord {
        if let preferredPeer {
            return preferredPeer
        }

        guard let sessionContext = await session.context else {
            throw LoomHostError.protocolViolation("Shared-host connected without authenticated session context.")
        }
        let sourceAppID = LoomHostCatalogCodec.sourceAppID(from: sessionContext.peerAdvertisement)
        let peerID = LoomPeerID(
            deviceID: sessionContext.peerIdentity.deviceID,
            appID: sourceAppID
        )
        if let currentPeer = currentPeerRecord(for: peerID) ?? currentPeerRecord(
            for: LoomPeerID(deviceID: sessionContext.peerIdentity.deviceID)
        ) {
            return currentPeer
        }

        return LoomHostPeerRecord(
            id: peerID,
            name: sessionContext.peerIdentity.name,
            deviceType: sessionContext.peerIdentity.deviceType,
            sources: signalingSessionID == nil ? [] : [.remoteSignaling],
            isNearby: false,
            remoteAccessEnabled: signalingSessionID != nil,
            signalingSessionID: signalingSessionID,
            advertisement: LoomPeerAdvertisement(
                deviceID: sessionContext.peerIdentity.deviceID,
                identityKeyID: sessionContext.peerIdentity.identityKeyID,
                deviceType: sessionContext.peerIdentity.deviceType
            ),
            bootstrapMetadata: nil,
            lastSeen: Date()
        )
    }

    private func makeHelloRequest(
        targetAppID: String?,
        sourceAppID: String?
    ) async throws -> LoomSessionHelloRequest {
        let profile = await makeDeviceProfile(for: sourceAppID)
        let identityKeyID = try await MainActor.run {
            try (dependencies.node.identityManager ?? LoomIdentityManager.shared).currentIdentity().keyID
        }
        let bootstrapMetadata = try await loadBootstrapMetadata()

        return try profile.makeHelloRequest(
            identityKeyID: identityKeyID,
            directTransports: currentDirectTransports()
        ) { metadata in
            let metadataWithBootstrap = try LoomHostMetadataCodec.addingBootstrapMetadata(
                bootstrapMetadata,
                to: metadata
            )
            let metadataWithCatalog = try LoomHostCatalogCodec.addingCatalog(
                self.hostCatalog(),
                to: metadataWithBootstrap
            )
            let metadataWithTargetAppID = LoomHostCatalogCodec.addingTargetAppID(
                targetAppID,
                to: metadataWithCatalog
            )
            return LoomHostCatalogCodec.addingSourceAppID(
                sourceAppID,
                to: metadataWithTargetAppID
            )
        }
    }

    private func makeAdvertisement() async throws -> LoomPeerAdvertisement {
        let profile = await makeDeviceProfile(for: nil)
        let identityKeyID = try await MainActor.run {
            try (dependencies.node.identityManager ?? LoomIdentityManager.shared).currentIdentity().keyID
        }
        let bootstrapMetadata = try await loadBootstrapMetadata()

        return try profile.makeAdvertisement(
            identityKeyID: identityKeyID,
            directTransports: currentDirectTransports()
        ) { metadata in
            let metadataWithBootstrap = try LoomHostMetadataCodec.addingBootstrapMetadata(
                bootstrapMetadata,
                to: metadata
            )
            return try LoomHostCatalogCodec.addingCatalog(
                self.hostCatalog(),
                to: metadataWithBootstrap
            )
        }
    }

    private func makeDeviceProfile(for appID: String?) async -> LoomDeviceProfile {
        let appFeatures = appID.flatMap { registeredApps[$0]?.descriptor.supportedFeatures } ?? []
        return LoomDeviceProfile(
            deviceID: dependencies.deviceID,
            deviceName: dependencies.serviceName,
            deviceType: Self.currentDeviceType(),
            iCloudUserID: await MainActor.run {
                dependencies.cloudKitManager?.currentUserRecordID
            },
            additionalAdvertisementMetadata: dependencies.hostAdvertisementMetadata,
            additionalSupportedFeatures: dependencies.hostSupportedFeatures + appFeatures
        )
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

    private func loadBootstrapMetadata() async throws -> LoomBootstrapMetadata? {
        try await dependencies.bootstrapMetadataProvider?()
    }

    private func hostCatalog() -> LoomHostCatalog? {
        let entries = registeredApps.values.map(\.descriptor.catalogEntry)
        guard !entries.isEmpty else {
            return nil
        }
        return LoomHostCatalog(entries: entries)
    }

    private func resolvedPeerName(
        localPeer: LoomPeer?,
        overlayPeer: LoomPeer?,
        cloudPeer: LoomCloudKitPeerInfo?
    ) -> String {
        if let localPeer,
           !localPeer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localPeer.name
        }
        if let overlayPeer,
           !overlayPeer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return overlayPeer.name
        }
        if let cloudPeer,
           !cloudPeer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cloudPeer.name
        }
        return "Unknown Peer"
    }

    private func notifyStateChanged() async {
        await onStateChanged(currentSnapshot())
    }

    private func record(_ error: Error) async {
        lastErrorMessage = error.localizedDescription
        await notifyStateChanged()
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

private struct LoomHostMetadata {
    let bootstrapMetadata: LoomBootstrapMetadata?

    init(advertisement: LoomPeerAdvertisement, cloudPeer: LoomCloudKitPeerInfo?) {
        bootstrapMetadata = LoomHostMetadataCodec.bootstrapMetadata(from: advertisement)
            ?? cloudPeer?.bootstrapMetadata
    }
}
