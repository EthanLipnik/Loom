//
//  LoomStoreOverlayTests.swift
//  LoomKit
//
//  Created by Codex on 3/11/26.
//

@testable import Loom
@testable import LoomKit
import Foundation
import Network
import Testing

@Suite("LoomKit Overlay Store", .serialized)
struct LoomStoreOverlayTests {
    @MainActor
    @Test("Store merges nearby and overlay sightings into one peer snapshot and overlay queries can filter it")
    func storeMergesNearbyAndOverlayPeerSources() async throws {
        let deviceID = UUID()
        let overlayDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!
        let serviceType = uniqueLoomKitServiceType(prefix: "lks")
        let overlayProbePort = UInt16.random(in: 20000...60000)
        let remoteProbeResponse = LoomOverlayProbeResponse(
            name: "Overlay Name",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: overlayDeviceID,
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 48016),
                ]
            )
        )
        let (remoteProbeServer, remoteProbeServerPort) = try await startLoomKitOverlayProbeServer(
            response: remoteProbeResponse
        )
        let configuration = LoomContainerConfiguration(
            serviceType: serviceType,
            serviceName: "Store Test Host",
            deviceIDSuiteName: "com.ethanlipnik.loom.tests.loomkit-store.\(UUID().uuidString)",
            overlayDirectory: LoomOverlayDirectoryConfiguration(
                refreshInterval: .seconds(3600),
                probeTimeout: .seconds(2),
                seedProvider: {
                    [LoomOverlaySeed(host: "127.0.0.1", probePort: remoteProbeServerPort)]
                }
            ),
            enablePeerToPeer: false
        )
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.loomkit-store-node.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                serviceType: serviceType,
                overlayProbePort: overlayProbePort,
                enablePeerToPeer: false,
                enabledDirectTransports: [.tcp]
            ),
            identityManager: identityManager
        )
        let store = LoomStore(
            configuration: configuration,
            deviceID: deviceID,
            node: node,
            trustStore: LoomTrustStore(
                suiteName: "com.ethanlipnik.loom.tests.loomkit-trust.\(UUID().uuidString)"
            ),
            cloudKitManager: nil,
            peerProvider: nil,
            shareManager: nil,
            relayClient: nil,
            connectionCoordinator: LoomConnectionCoordinator(node: node)
        )
        let snapshots = await store.makeSnapshotStream()

        do {
            try await withLoomKitTimeout(.seconds(5), operation: "store.start()") {
                try await store.start()
            }

            let localPeer = LoomPeer(
                id: overlayDeviceID,
                name: "Nearby Name",
                deviceType: .mac,
                endpoint: .hostPort(
                    host: "127.0.0.1",
                    port: .init(rawValue: 49016)!
                ),
                advertisement: LoomPeerAdvertisement(
                    deviceID: overlayDeviceID,
                    deviceType: .mac,
                    directTransports: [
                        LoomDirectTransportAdvertisement(transportKind: .tcp, port: 49016),
                    ]
                )
            )

            let discovery = try #require(await MainActor.run { node.discovery })
            await MainActor.run {
                discovery.upsertPeerForTesting(localPeer)
            }
            await store.refreshPeers()

            let snapshot = try #require(
                await firstMatchingSnapshot(
                    from: snapshots,
                    timeout: .seconds(5)
                ) { snapshot in
                    snapshot.peers.contains { peer in
                        peer.id == localPeer.id &&
                            Set(peer.sources) == Set([LoomPeerSource.nearby, .overlay])
                    }
                }
            )
            let peer = try #require(snapshot.peers.first { $0.id == localPeer.id })

            #expect(peer.name == "Nearby Name")
            #expect(peer.isNearby)
            #expect(Set(peer.sources) == Set([LoomPeerSource.nearby, .overlay]))
            #expect(
                LoomQueryEvaluator.filterPeers(snapshot.peers, filter: .overlay)
                    .map { $0.id } == [peer.id]
            )
        } catch {
            await store.stop()
            await remoteProbeServer.stop()
            throw error
        }

        await store.stop()
        await remoteProbeServer.stop()
    }
}

private func startLoomKitOverlayProbeServer(
    response: LoomOverlayProbeResponse
) async throws -> (LoomOverlayProbeServer, UInt16) {
    var lastError: Error?

    for _ in 0..<16 {
        let server = LoomOverlayProbeServer(
            port: UInt16.random(in: 20000...60000)
        ) {
            response
        }
        do {
            let port = try await server.start()
            return (server, port)
        } catch {
            lastError = error
        }
    }

    throw lastError ?? LoomError.protocolError("Unable to reserve a LoomKit overlay probe port.")
}

private func firstMatchingSnapshot(
    from stream: AsyncStream<LoomStoreSnapshot>,
    timeout: Duration,
    where predicate: @escaping @Sendable (LoomStoreSnapshot) -> Bool
) async -> LoomStoreSnapshot? {
    await withTaskGroup(of: LoomStoreSnapshot?.self) { group in
        group.addTask {
            for await snapshot in stream {
                if predicate(snapshot) {
                    return snapshot
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }

        let snapshot = await group.next() ?? nil
        group.cancelAll()
        return snapshot
    }
}

private func withLoomKitTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await body()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LoomKitTimeoutError(operation: operation)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct LoomKitTimeoutError: Error, CustomStringConvertible {
    let operation: String

    var description: String {
        "Timed out waiting for \(operation)"
    }
}

private func uniqueLoomKitServiceType(prefix: String) -> String {
    "_\(prefix)\(UUID().uuidString.prefix(6).lowercased())._tcp"
}
