//
//  LoomOverlayDirectoryTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import Loom
import Foundation
import Network
import Testing

@Suite("Loom Overlay Directory", .serialized)
struct LoomOverlayDirectoryTests {
    @MainActor
    @Test("Overlay probe client decodes the peer payload")
    func probeClientDecodesPeerPayload() async throws {
        let response = LoomOverlayProbeResponse(
            name: "Overlay Mac",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000010"),
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41001),
                ],
                metadata: ["overlay": "1"]
            )
        )
        let (server, port) = try await startOverlayProbeServer(response: response)

        do {
            let decoded = try await LoomOverlayProbeClient.probe(
                seed: LoomOverlaySeed(host: "127.0.0.1", probePort: port),
                defaultPort: Loom.defaultOverlayProbePort,
                timeout: .seconds(2)
            )

            #expect(decoded == response)
        } catch {
            await server.stop()
            throw error
        }

        await server.stop()
    }

    @MainActor
    @Test("Overlay directory refreshes from the current seed set")
    func directoryRefreshesCurrentSeeds() async throws {
        let firstResponse = LoomOverlayProbeResponse(
            name: "Alpha",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000011"),
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41011),
                ]
            )
        )
        let secondResponse = LoomOverlayProbeResponse(
            name: "Beta",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000012"),
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41012),
                ]
            )
        )
        let (firstServer, firstPort) = try await startOverlayProbeServer(response: firstResponse)
        let (secondServer, secondPort) = try await startOverlayProbeServer(response: secondResponse)
        let seedState = LoomOverlaySeedState(
            seeds: [LoomOverlaySeed(host: "127.0.0.1", probePort: firstPort)]
        )
        let directory = LoomOverlayDirectory(
            configuration: LoomOverlayDirectoryConfiguration(
                refreshInterval: .seconds(3600),
                probeTimeout: .seconds(2),
                seedProvider: {
                    await seedState.currentSeeds()
                }
            )
        )

        do {
            await directory.refresh()
            #expect(directory.discoveredPeers.map { $0.name } == ["Alpha"])

            await seedState.setSeeds([
                LoomOverlaySeed(host: "127.0.0.1", probePort: secondPort),
            ])
            await directory.refresh()
            #expect(directory.discoveredPeers.map { $0.name } == ["Beta"])
        } catch {
            await firstServer.stop()
            await secondServer.stop()
            throw error
        }

        await firstServer.stop()
        await secondServer.stop()
    }

    @Test("Overlay probe timeout cancels stalled connection")
    func probeTimeoutCancelsStalledConnection() async throws {
        let listener = try await startBlackholeTCPServer()
        defer {
            listener.cancel()
        }

        let port = try #require(listener.port?.rawValue)
        let start = ContinuousClock.now

        await #expect(throws: Error.self) {
            _ = try await LoomOverlayProbeClient.probe(
                seed: LoomOverlaySeed(host: "127.0.0.1", probePort: port),
                defaultPort: Loom.defaultOverlayProbePort,
                timeout: .milliseconds(100)
            )
        }

        #expect(start.duration(to: ContinuousClock.now) < .seconds(1))
    }

    @MainActor
    @Test("Overlay directory suppresses duplicate semantic peer snapshots")
    func directorySuppressesDuplicateNotifications() async throws {
        let response = LoomOverlayProbeResponse(
            name: "Alpha",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000031"),
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41031),
                ]
            )
        )
        let (server, port) = try await startOverlayProbeServer(response: response)
        let seedState = LoomOverlaySeedState(
            seeds: [LoomOverlaySeed(host: "127.0.0.1", probePort: port)]
        )
        let directory = LoomOverlayDirectory(
            configuration: LoomOverlayDirectoryConfiguration(
                refreshInterval: .seconds(3600),
                probeTimeout: .seconds(2),
                seedProvider: {
                    await seedState.currentSeeds()
                }
            )
        )

        var notificationCount = 0
        let token = directory.addPeersChangedObserver { _ in
            notificationCount += 1
        }
        defer {
            directory.removePeersChangedObserver(token)
        }

        await directory.refresh()
        await directory.refresh()
        #expect(notificationCount == 1)
        await server.stop()
    }

    @MainActor
    @Test("Overlay directory collapses duplicate seeds and prefers QUIC-capable peers")
    func directoryPrefersQUICCandidateWhenSeedsDuplicateOnePeer() async throws {
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let (tcpServer, tcpPort) = try await startOverlayProbeServer(
            response: LoomOverlayProbeResponse(
                name: "Overlay Host",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement(
                    deviceID: deviceID,
                    deviceType: .mac,
                    directTransports: [
                        LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41013),
                    ]
                )
            )
        )
        let quicPort: UInt16 = 51013
        let (quicServer, quicProbePort) = try await startOverlayProbeServer(
            response: LoomOverlayProbeResponse(
                name: "Overlay Host",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement(
                    deviceID: deviceID,
                    deviceType: .mac,
                    directTransports: [
                        LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41014),
                        LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort),
                    ]
                )
            )
        )
        let directory = LoomOverlayDirectory(
            configuration: LoomOverlayDirectoryConfiguration(
                refreshInterval: .seconds(3600),
                probeTimeout: .seconds(2),
                seedProvider: {
                    [
                        LoomOverlaySeed(host: "127.0.0.1", probePort: tcpPort),
                        LoomOverlaySeed(host: "localhost", probePort: quicProbePort),
                    ]
                }
            )
        )

        do {
            await directory.refresh()

            #expect(directory.discoveredPeers.count == 1)
            let peer = try #require(directory.discoveredPeers.first)
            #expect(
                peer.advertisement.directTransports.contains {
                    $0.transportKind == LoomTransportKind.quic
                }
            )
            #expect(endpointHost(peer.endpoint) == "localhost")
            #expect(endpointPort(peer.endpoint) == quicPort)
        } catch {
            await tcpServer.stop()
            await quicServer.stop()
            throw error
        }

        await tcpServer.stop()
        await quicServer.stop()
    }

    @MainActor
    @Test("Overlay directory applies lexical host tie-breaks and projects shared host catalogs")
    func directoryProjectsCatalogFromPreferredSeed() async throws {
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        let catalog = LoomHostCatalog(
            entries: [
                LoomHostCatalogEntry(
                    appID: "com.example.alpha",
                    displayName: "Alpha",
                    metadata: ["alpha": "1"]
                ),
                LoomHostCatalogEntry(
                    appID: "com.example.beta",
                    displayName: "Beta",
                    metadata: ["beta": "1"]
                ),
            ]
        )
        let metadata = try LoomHostCatalogCodec.addingCatalog(catalog, to: [:])
        let response = LoomOverlayProbeResponse(
            name: "Shared Host",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: deviceID,
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41015),
                ],
                metadata: metadata
            )
        )
        let (localhostServer, localhostPort) = try await startOverlayProbeServer(response: response)
        let (loopbackServer, loopbackPort) = try await startOverlayProbeServer(response: response)
        let directory = LoomOverlayDirectory(
            configuration: LoomOverlayDirectoryConfiguration(
                refreshInterval: .seconds(3600),
                probeTimeout: .seconds(2),
                seedProvider: {
                    [
                        LoomOverlaySeed(host: "localhost", probePort: localhostPort),
                        LoomOverlaySeed(host: "127.0.0.1", probePort: loopbackPort),
                    ]
                }
            )
        )

        do {
            await directory.refresh()

            #expect(directory.discoveredPeers.count == 2)
            #expect(Set(directory.discoveredPeers.compactMap { $0.appID }) == [
                "com.example.alpha",
                "com.example.beta",
            ])
            #expect(Set(directory.discoveredPeers.map { endpointHost($0.endpoint) }) == ["127.0.0.1"])

            let alphaPeer = try #require(
                directory.discoveredPeers.first { $0.appID == "com.example.alpha" }
            )
            #expect(alphaPeer.name == "Alpha")
            #expect(alphaPeer.advertisement.metadata["alpha"] == "1")
            #expect(alphaPeer.advertisement.metadata[LoomHostCatalogCodec.metadataKey] == nil)
        } catch {
            await localhostServer.stop()
            await loopbackServer.stop()
            throw error
        }

        await localhostServer.stop()
        await loopbackServer.stop()
    }

    @MainActor
    @Test("Overlay directory clears published peers after a throwing refresh")
    func directoryClearsPeersWhenSeedRefreshThrows() async throws {
        let response = LoomOverlayProbeResponse(
            name: "Gamma",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000017"),
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 41017),
                ]
            )
        )
        let (server, port) = try await startOverlayProbeServer(response: response)
        let seedState = ThrowingLoomOverlaySeedState(
            seeds: [LoomOverlaySeed(host: "127.0.0.1", probePort: port)]
        )
        let directory = LoomOverlayDirectory(
            configuration: LoomOverlayDirectoryConfiguration(
                refreshInterval: .seconds(3600),
                probeTimeout: .seconds(2),
                seedProvider: {
                    try await seedState.currentSeeds()
                }
            )
        )

        do {
            await directory.refresh()
            #expect(directory.discoveredPeers.map(\.name) == ["Gamma"])

            await seedState.setShouldFail(true)
            await directory.refresh()

            #expect(directory.discoveredPeers.isEmpty)
            #expect(directory.isSearching == false)
        } catch {
            await server.stop()
            throw error
        }

        await server.stop()
    }
}

private actor LoomOverlaySeedState {
    private var seeds: [LoomOverlaySeed]

    init(seeds: [LoomOverlaySeed]) {
        self.seeds = seeds
    }

    func currentSeeds() -> [LoomOverlaySeed] {
        seeds
    }

    func setSeeds(_ seeds: [LoomOverlaySeed]) {
        self.seeds = seeds
    }
}

private actor ThrowingLoomOverlaySeedState {
    private var seeds: [LoomOverlaySeed]
    private var shouldFail = false

    init(seeds: [LoomOverlaySeed]) {
        self.seeds = seeds
    }

    func currentSeeds() throws -> [LoomOverlaySeed] {
        if shouldFail {
            throw OverlaySeedProviderFailure()
        }
        return seeds
    }

    func setShouldFail(_ shouldFail: Bool) {
        self.shouldFail = shouldFail
    }
}

private struct OverlaySeedProviderFailure: Error, Sendable {}

private func startOverlayProbeServer(
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

    throw lastError ?? LoomError.protocolError("Unable to reserve an overlay probe port.")
}

private func startBlackholeTCPServer() async throws -> NWListener {
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global(qos: .userInitiated))
    }

    return try await withCheckedThrowingContinuation { continuation in
        let continuationBox = TestContinuationBox<NWListener>(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuationBox.resume(returning: listener)
            case let .failed(error):
                continuationBox.resume(throwing: error)
            case .cancelled:
                continuationBox.resume(throwing: LoomError.connectionFailed(CancellationError()))
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }
}

private func endpointHost(_ endpoint: NWEndpoint) -> String? {
    guard case let .hostPort(host, _) = endpoint else {
        return nil
    }
    return "\(host)"
}

private func endpointPort(_ endpoint: NWEndpoint) -> UInt16? {
    guard case let .hostPort(_, port) = endpoint else {
        return nil
    }
    return port.rawValue
}

private final class TestContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
