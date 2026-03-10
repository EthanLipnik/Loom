//
//  LoomKitIntegrationTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

@testable import Loom
@testable import LoomKit
import Foundation
import Network
import Testing

@Suite("LoomKit Integration", .serialized)
struct LoomKitIntegrationTests {
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
            identityManager: pair.serverIdentityManager
        )
        _ = try await (clientContext, serverContext)

        let clientHandle = makeHandle(
            session: pair.client,
            peerID: pair.serverHello.deviceID,
            peerName: pair.serverHello.deviceName
        )
        let serverHandle = makeHandle(
            session: pair.server,
            peerID: pair.clientHello.deviceID,
            peerName: pair.clientHello.deviceName
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
            identityManager: pair.serverIdentityManager
        )
        _ = try await (clientContext, serverContext)

        let clientHandle = makeHandle(
            session: pair.client,
            peerID: pair.serverHello.deviceID,
            peerName: pair.serverHello.deviceName
        )
        let serverHandle = makeHandle(
            session: pair.server,
            peerID: pair.clientHello.deviceID,
            peerName: pair.clientHello.deviceName
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
    private func makeHandle(
        session: LoomAuthenticatedSession,
        peerID: UUID,
        peerName: String
    ) -> LoomConnectionHandle {
        LoomConnectionHandle(
            id: UUID(),
            peer: LoomPeerSnapshot(
                id: peerID,
                name: peerName,
                deviceType: .mac,
                sources: [.nearby],
                isNearby: true,
                isShared: false,
                remoteAccessEnabled: false,
                relaySessionID: nil,
                advertisement: LoomPeerAdvertisement(
                    deviceID: peerID,
                    deviceType: .mac
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
        rawSession: LoomSession(connection: clientConnection),
        role: .initiator,
        transportKind: .tcp
    )
    let server = LoomAuthenticatedSession(
        rawSession: LoomSession(connection: serverConnection),
        role: .receiver,
        transportKind: .tcp
    )

    let clientHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Client",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac)
    )
    let serverHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Server",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac)
    )

    return LoomKitLoopbackSessionPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        clientHello: clientHello,
        serverHello: serverHello,
        client: client,
        server: server
    )
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
