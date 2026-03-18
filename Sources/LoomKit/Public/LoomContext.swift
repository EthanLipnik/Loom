//
//  LoomContext.swift
//  LoomKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CloudKit
import Foundation
import Loom
import Observation

/// Main-actor app-facing projection over a shared LoomKit runtime store.
@Observable
@MainActor
public final class LoomContext {
    /// Current merged peer snapshots for nearby and CloudKit-visible devices.
    public private(set) var peers: [LoomPeerSnapshot] = []
    /// Current connection snapshots tracked by the shared runtime.
    public private(set) var connections: [LoomConnectionSnapshot] = []
    /// Current transfer snapshots tracked across all active connections.
    public private(set) var transfers: [LoomTransferSnapshot] = []
    /// Indicates whether the shared Loom runtime is active.
    public private(set) var isRunning = false
    /// Indicates whether this local peer is currently publishing signaling-backed reachability.
    public private(set) var isPublishingRemoteReachability = false
    /// Current capability projection for the local peer runtime.
    public private(set) var localPeerCapabilities: LoomPeerCapabilities = .none
    /// Last runtime error projected into the UI layer.
    public private(set) var lastError: LoomKitError?
    /// Optional recovery surface for peers that publish bootstrap metadata.
    public let bootstrap: LoomBootstrapCoordinator

    /// Stream of newly accepted incoming connections.
    public nonisolated let incomingConnections: AsyncStream<LoomConnectionHandle>

    private let store: LoomStore
    private let incomingConnectionsContinuation: AsyncStream<LoomConnectionHandle>.Continuation
    private var snapshotTask: Task<Void, Never>?
    private var incomingConnectionsTask: Task<Void, Never>?

    init(store: LoomStore) {
        self.store = store
        bootstrap = LoomBootstrapCoordinator(store: store)
        let (incomingConnections, incomingConnectionsContinuation) = AsyncStream.makeStream(of: LoomConnectionHandle.self)
        self.incomingConnections = incomingConnections
        self.incomingConnectionsContinuation = incomingConnectionsContinuation

        snapshotTask = Task { [weak self] in
            let snapshots = await store.makeSnapshotStream()
            for await snapshot in snapshots {
                guard let self else {
                    return
                }
                await MainActor.run {
                    self.apply(snapshot)
                }
            }
        }
        incomingConnectionsTask = Task { [weak self] in
            let incomingConnections = await store.makeIncomingConnectionsStream()
            for await connection in incomingConnections {
                guard let self else {
                    return
                }
                self.incomingConnectionsContinuation.yield(connection)
            }
            self?.incomingConnectionsContinuation.finish()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            snapshotTask?.cancel()
            incomingConnectionsTask?.cancel()
            incomingConnectionsContinuation.finish()
        }
    }

    /// Starts the shared LoomKit runtime if needed.
    public func start() async throws {
        try await store.start()
    }

    /// Stops the shared LoomKit runtime and clears active state.
    public func stop() async {
        await store.stop()
    }

    /// Forces a local-discovery and CloudKit peer refresh.
    public func refreshPeers() async {
        await store.refreshPeers()
    }

    /// Connects to a unified LoomKit peer snapshot.
    public func connect(_ peer: LoomPeerSnapshot) async throws -> LoomConnectionHandle {
        try await store.connect(to: peer)
    }

    /// Connects through signaling using a known remote session identifier.
    public func connect(remoteSessionID: String) async throws -> LoomConnectionHandle {
        try await store.connect(remoteSessionID: remoteSessionID)
    }

    /// Disconnects a currently tracked LoomKit connection snapshot.
    public func disconnect(_ connection: LoomConnectionSnapshot) async {
        await store.disconnect(connectionID: connection.id)
    }

    /// Publishes signaling-backed remote reachability for the local peer.
    public func publishRemoteReachability(
        sessionID: String,
        publicHostForTCP: String? = nil
    ) async throws {
        try await store.startRemoteHosting(
            sessionID: sessionID,
            publicHostForTCP: publicHostForTCP
        )
    }

    /// Stops publishing signaling-backed remote reachability for the local peer.
    public func stopPublishingRemoteReachability() async {
        await store.stopRemoteHosting()
    }

    /// Creates or returns the current CloudKit share for the local peer publication.
    public func createShare() async throws -> CKShare {
        try await store.createShare()
    }

    /// Accepts an incoming CloudKit share and refreshes unified peer state.
    public func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await store.acceptShare(metadata)
    }

    private func apply(_ snapshot: LoomStoreSnapshot) {
        peers = snapshot.peers
        connections = snapshot.connections
        transfers = snapshot.transfers
        isRunning = snapshot.isRunning
        isPublishingRemoteReachability = snapshot.isPublishingRemoteReachability
        localPeerCapabilities = snapshot.localPeerCapabilities
        lastError = snapshot.lastErrorMessage.map(LoomKitError.init(message:))
    }
}
