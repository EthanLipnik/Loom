//
//  LoomKitIntegrationTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import Loom
@testable import LoomKit
import Foundation
import Network
import Testing

@Suite("LoomKit Integration", .serialized)
struct LoomKitIntegrationTests {
    @MainActor
    @Test("iOS-shaped peers exchange messages in both directions")
    func iosShapedPeersExchangeMessagesInBothDirections() async throws {
        let pair = try await makeLoopbackPair(
            clientDeviceType: .iPhone,
            serverDeviceType: .iPad
        )
        defer {
            Task {
                await pair.stop()
            }
        }

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        _ = try await (clientContext, serverContext)

        let clientHandle = makeHandle(
            session: pair.client,
            peerID: pair.serverHello.deviceID,
            peerName: pair.serverHello.deviceName,
            peerDeviceType: pair.serverHello.deviceType
        )
        let serverHandle = makeHandle(
            session: pair.server,
            peerID: pair.clientHello.deviceID,
            peerName: pair.clientHello.deviceName,
            peerDeviceType: pair.clientHello.deviceType
        )
        await clientHandle.startObservers()
        await serverHandle.startObservers()

        let serverReceiveTask = Task<Data?, Never> {
            for await payload in serverHandle.messages {
                return payload
            }
            return nil
        }
        let clientReceiveTask = Task<Data?, Never> {
            for await payload in clientHandle.messages {
                return payload
            }
            return nil
        }

        try await clientHandle.send("hello from iphone")
        try await serverHandle.send("hello from ipad")

        let serverPayload = try #require(
            try await withTimeout(seconds: 2) {
                await serverReceiveTask.value
            }
        )
        let clientPayload = try #require(
            try await withTimeout(seconds: 2) {
                await clientReceiveTask.value
            }
        )

        #expect(serverPayload == Data("hello from iphone".utf8))
        #expect(clientPayload == Data("hello from ipad".utf8))

        await clientHandle.disconnect()
        await serverHandle.disconnect()
    }

    @MainActor
    @Test("Connection handles send messages on the default LoomKit stream")
    func connectionHandlesSendMessages() async throws {
        let pair = try await makeLoopbackPair()
        defer {
            Task {
                await pair.stop()
            }
        }

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        _ = try await (clientContext, serverContext)

        let clientHandle = makeHandle(
            session: pair.client,
            peerID: pair.serverHello.deviceID,
            peerName: pair.serverHello.deviceName,
            peerDeviceType: pair.serverHello.deviceType
        )
        let serverHandle = makeHandle(
            session: pair.server,
            peerID: pair.clientHello.deviceID,
            peerName: pair.clientHello.deviceName,
            peerDeviceType: pair.clientHello.deviceType
        )
        await clientHandle.startObservers()
        await serverHandle.startObservers()

        let receivedMessageTask = Task<Data?, Never> {
            for await payload in serverHandle.messages {
                return payload
            }
            return nil
        }

        try await clientHandle.send("hello loomkit")

        let receivedPayload = try #require(
            try await withTimeout(seconds: 2) {
                await receivedMessageTask.value
            }
        )
        #expect(receivedPayload == Data("hello loomkit".utf8))

        await clientHandle.disconnect()
        await serverHandle.disconnect()
    }

    @MainActor
    @Test("Connection handles wrap Loom transfer offers for in-memory data")
    func connectionHandlesTransferData() async throws {
        let pair = try await makeLoopbackPair()
        defer {
            Task {
                await pair.stop()
            }
        }

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        _ = try await (clientContext, serverContext)

        let clientHandle = makeHandle(
            session: pair.client,
            peerID: pair.serverHello.deviceID,
            peerName: pair.serverHello.deviceName,
            peerDeviceType: pair.serverHello.deviceType
        )
        let serverHandle = makeHandle(
            session: pair.server,
            peerID: pair.clientHello.deviceID,
            peerName: pair.clientHello.deviceName,
            peerDeviceType: pair.clientHello.deviceType
        )
        await clientHandle.startObservers()
        await serverHandle.startObservers()

        let payload = Data("loomkit transfer payload".utf8)
        let incomingTransferTask = Task<LoomIncomingTransfer?, Never> {
            for await transfer in serverHandle.incomingTransfers {
                return transfer
            }
            return nil
        }

        let outgoingTransfer = try await clientHandle.sendData(
            payload,
            named: "payload.bin",
            contentType: "application/octet-stream"
        )
        let incomingTransfer = try #require(
            try await withTimeout(seconds: 2) {
                await incomingTransferTask.value
            }
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let destinationURL = temporaryDirectory.appendingPathComponent("payload.bin")

        let outgoingCompletionTask = Task<LoomTransferState?, Never> {
            for await progress in outgoingTransfer.makeProgressObserver() {
                if progress.state == .completed {
                    return progress.state
                }
            }
            return nil
        }
        let incomingCompletionTask = Task<LoomTransferState?, Never> {
            for await progress in incomingTransfer.makeProgressObserver() {
                if progress.state == .completed {
                    return progress.state
                }
            }
            return nil
        }

        try await serverHandle.accept(incomingTransfer, to: destinationURL)

        let outgoingState = try #require(
            try await withTimeout(seconds: 2) {
                await outgoingCompletionTask.value
            }
        )
        let incomingState = try #require(
            try await withTimeout(seconds: 2) {
                await incomingCompletionTask.value
            }
        )
        #expect(outgoingState == .completed)
        #expect(incomingState == .completed)
        #expect(try Data(contentsOf: destinationURL) == payload)

        await clientHandle.disconnect()
        await serverHandle.disconnect()
    }

    @MainActor
    @Test("Container creates secondary contexts with shared initial state")
    func containerCreatesSecondaryContexts() throws {
        let container = try LoomContainer(
            for: LoomContainerConfiguration(
                serviceName: "Test Device"
            )
        )

        let secondaryContext = container.makeContext()

        #expect(container.mainContext.peers == secondaryContext.peers)
        #expect(container.mainContext.connections == secondaryContext.connections)
        #expect(container.mainContext.transfers == secondaryContext.transfers)
        #expect(container.mainContext.isRunning == secondaryContext.isRunning)
    }

    @MainActor
    @Test("One local runtime can send the same payload to multiple peers")
    func oneLocalRuntimeCanSendSamePayloadToMultiplePeers() async throws {
        let firstPair = try await makeLoopbackPair(
            clientDeviceType: .iPhone,
            serverDeviceType: .iPhone
        )
        let secondPair = try await makeLoopbackPair(
            clientDeviceType: .iPhone,
            serverDeviceType: .iPad
        )
        defer {
            Task {
                await firstPair.stop()
                await secondPair.stop()
            }
        }

        async let firstClientContext = firstPair.client.start(
            localHello: firstPair.clientHello,
            identityManager: firstPair.clientIdentityManager
        )
        async let firstServerContext = firstPair.server.start(
            localHello: firstPair.serverHello,
            identityManager: firstPair.serverIdentityManager,
            trustProvider: firstPair.serverTrustProvider
        )
        async let secondClientContext = secondPair.client.start(
            localHello: secondPair.clientHello,
            identityManager: secondPair.clientIdentityManager
        )
        async let secondServerContext = secondPair.server.start(
            localHello: secondPair.serverHello,
            identityManager: secondPair.serverIdentityManager,
            trustProvider: secondPair.serverTrustProvider
        )
        _ = try await (
            firstClientContext,
            firstServerContext,
            secondClientContext,
            secondServerContext
        )

        let firstClientHandle = makeHandle(
            session: firstPair.client,
            peerID: firstPair.serverHello.deviceID,
            peerName: firstPair.serverHello.deviceName,
            peerDeviceType: firstPair.serverHello.deviceType
        )
        let firstServerHandle = makeHandle(
            session: firstPair.server,
            peerID: firstPair.clientHello.deviceID,
            peerName: firstPair.clientHello.deviceName,
            peerDeviceType: firstPair.clientHello.deviceType
        )
        let secondClientHandle = makeHandle(
            session: secondPair.client,
            peerID: secondPair.serverHello.deviceID,
            peerName: secondPair.serverHello.deviceName,
            peerDeviceType: secondPair.serverHello.deviceType
        )
        let secondServerHandle = makeHandle(
            session: secondPair.server,
            peerID: secondPair.clientHello.deviceID,
            peerName: secondPair.clientHello.deviceName,
            peerDeviceType: secondPair.clientHello.deviceType
        )
        await firstClientHandle.startObservers()
        await firstServerHandle.startObservers()
        await secondClientHandle.startObservers()
        await secondServerHandle.startObservers()

        let payload = Data("mesh payload".utf8)
        let firstReceiveTask = Task<Data?, Never> {
            for await message in firstServerHandle.messages {
                return message
            }
            return nil
        }
        let secondReceiveTask = Task<Data?, Never> {
            for await message in secondServerHandle.messages {
                return message
            }
            return nil
        }

        try await firstClientHandle.send(payload)
        try await secondClientHandle.send(payload)

        let firstReceived = try #require(
            try await withTimeout(seconds: 2) {
                await firstReceiveTask.value
            }
        )
        let secondReceived = try #require(
            try await withTimeout(seconds: 2) {
                await secondReceiveTask.value
            }
        )

        #expect(firstReceived == payload)
        #expect(secondReceived == payload)
    }

    @MainActor
    @Test("Peer snapshots derive connectivity and bootstrap capabilities")
    func peerSnapshotsDeriveCapabilities() {
        let bootstrapMetadata = LoomBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: true,
            endpoints: [.init(host: "studio.example.com", port: 22, source: .user)],
            sshPort: 22,
            controlPort: 9849,
            wakeOnLAN: .init(
                macAddress: "AA:BB:CC:DD:EE:FF",
                broadcastAddresses: ["192.168.1.255"]
            )
        )
        let peer = LoomPeerSnapshot(
            id: UUID(),
            name: "Studio iPad",
            deviceType: .iPad,
            sources: [.nearby, .remoteSignaling],
            isNearby: true,
            remoteAccessEnabled: true,
            signalingSessionID: "studio-ipad",
            advertisement: LoomPeerAdvertisement(
                deviceType: .iPad,
                directTransports: [
                    LoomDirectTransportAdvertisement(
                        transportKind: .tcp,
                        port: 4040
                    )
                ]
            ),
            bootstrapMetadata: bootstrapMetadata,
            lastSeen: Date()
        )

        #expect(peer.capabilities.connectivity.supportsNearbyDirectConnections)
        #expect(peer.capabilities.connectivity.supportsRemoteSignalingReachability)
        #expect(peer.capabilities.bootstrap.supportsWakeOnLAN)
        #expect(peer.capabilities.bootstrap.supportsSSHUnlock)
        #expect(peer.capabilities.bootstrap.supportsPreloginControl)
    }

    @MainActor
    @Test("Bootstrap coordinator rejects peers without published recovery capability")
    func bootstrapCoordinatorRejectsUnsupportedPeers() async throws {
        let container = try LoomContainer(
            for: LoomContainerConfiguration(serviceName: "Test Phone")
        )
        let peer = LoomPeerSnapshot(
            id: UUID(),
            name: "Peer",
            deviceType: .iPhone,
            sources: [.nearby],
            isNearby: true,
            remoteAccessEnabled: false,
            signalingSessionID: nil,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(),
                deviceType: .iPhone
            ),
            bootstrapMetadata: nil,
            lastSeen: Date()
        )

        await #expect(throws: LoomKitError.self) {
            try await container.mainContext.bootstrap.wake(peer)
        }
    }

    @MainActor
    private func makeHandle(
        session: LoomAuthenticatedSession,
        peerID: UUID,
        peerName: String,
        peerDeviceType: DeviceType
    ) -> LoomConnectionHandle {
        LoomConnectionHandle(
            id: UUID(),
            peer: LoomPeerSnapshot(
                id: peerID,
                name: peerName,
                deviceType: peerDeviceType,
                sources: [.nearby],
                isNearby: true,
                remoteAccessEnabled: false,
                signalingSessionID: nil,
                advertisement: LoomPeerAdvertisement(
                    deviceID: peerID,
                    deviceType: peerDeviceType
                ),
                bootstrapMetadata: nil,
                lastSeen: Date()
            ),
            session: session,
            transferConfiguration: .default,
            onStateChanged: { _, _, _ in },
            onTransferChanged: { _ in },
            onDisconnected: { _, _ in }
        )
    }
}

private struct LoomKitLoopbackSessionPair {
    let listener: NWListener
    let clientIdentityManager: LoomIdentityManager
    let serverIdentityManager: LoomIdentityManager
    let serverTrustProvider: AlwaysTrustProvider
    let clientHello: LoomSessionHelloRequest
    let serverHello: LoomSessionHelloRequest
    let client: LoomAuthenticatedSession
    let server: LoomAuthenticatedSession

    func stop() async {
        listener.cancel()
        await client.cancel()
        await server.cancel()
    }
}

@MainActor
private func makeLoopbackPair() async throws -> LoomKitLoopbackSessionPair {
    try await makeLoopbackPair(
        clientDeviceType: .mac,
        serverDeviceType: .mac
    )
}

@MainActor
private func makeLoopbackPair(
    clientDeviceType: DeviceType,
    serverDeviceType: DeviceType
) async throws -> LoomKitLoopbackSessionPair {
    let clientIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.loomkit-client.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.loomkit-server.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )

    let listener = try NWListener(using: .tcp, on: .any)
    let acceptedConnection = AsyncBox<NWConnection>()
    let readyPort = AsyncBox<UInt16>()

    listener.newConnectionHandler = { connection in
        Task {
            await acceptedConnection.set(connection)
        }
    }
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue {
            Task {
                await readyPort.set(port)
            }
        }
    }
    listener.start(queue: .global(qos: .userInitiated))

    let port = try #require(await readyPort.take())
    let clientConnection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tcp
    )
    let serverConnection = try #require(await acceptedConnection.take(after: {
        clientConnection.start(queue: .global(qos: .userInitiated))
    }))

    let client = LoomAuthenticatedSession(
        connection: .tcp(clientConnection),
        role: .initiator
    )
    let server = LoomAuthenticatedSession(
        connection: .tcp(serverConnection),
        role: .receiver
    )

    let clientHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Client",
        deviceType: clientDeviceType,
        advertisement: LoomPeerAdvertisement(deviceType: clientDeviceType)
    )
    let serverHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Server",
        deviceType: serverDeviceType,
        advertisement: LoomPeerAdvertisement(deviceType: serverDeviceType)
    )

    return LoomKitLoopbackSessionPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        serverTrustProvider: AlwaysTrustProvider(),
        clientHello: clientHello,
        serverHello: serverHello,
        client: client,
        server: server
    )
}

@MainActor
private final class AlwaysTrustProvider: LoomTrustProvider {
    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        .trusted
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {}

    func revokeTrust(for deviceID: UUID) async throws {}
}

private actor AsyncBox<Value: Sendable> {
    private var value: Value?
    private var continuations: [CheckedContinuation<Value?, Never>] = []

    func set(_ newValue: Value) {
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume(returning: newValue)
            return
        }
        value = newValue
    }

    func take(after action: @escaping @Sendable () -> Void) async -> Value? {
        action()
        return await take()
    }

    func take() async -> Value? {
        if let value {
            self.value = nil
            return value
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private func withTimeout<T: Sendable>(
    seconds: Int64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LoomError.timeout
        }

        guard let result = try await group.next() else {
            throw LoomError.timeout
        }
        group.cancelAll()
        return result
    }
}
