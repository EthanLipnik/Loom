//
//  LoomAuthenticatedSessionTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

@testable import Loom
import Foundation
import Network
import Testing

@Suite("Loom Authenticated Session", .serialized)
struct LoomAuthenticatedSessionTests {
    @MainActor
    @Test("Hello validation rejects tampered ephemeral key shares")
    func tamperedEphemeralKeyShareRejected() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.session-ephemeral.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let request = LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Ephemeral Test",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement()
        )
        let hello = try LoomSessionHelloValidator.makeSignedHello(
            from: request,
            identityManager: identityManager
        )
        let tamperedIdentity = LoomSessionHello.Identity(
            keyID: hello.identity.keyID,
            publicKey: hello.identity.publicKey,
            ephemeralPublicKey: Data(hello.identity.ephemeralPublicKey.reversed()),
            timestampMs: hello.identity.timestampMs,
            nonce: hello.identity.nonce,
            signature: hello.identity.signature
        )
        let tamperedHello = LoomSessionHello(
            deviceID: hello.deviceID,
            deviceName: hello.deviceName,
            deviceType: hello.deviceType,
            protocolVersion: hello.protocolVersion,
            advertisement: hello.advertisement,
            supportedFeatures: hello.supportedFeatures,
            iCloudUserID: hello.iCloudUserID,
            identity: tamperedIdentity
        )

        let validator = LoomSessionHelloValidator()
        await #expect(throws: LoomSessionHelloError.invalidSignature) {
            try await validator.validate(tamperedHello, endpointDescription: "127.0.0.1:1")
        }
    }

    @MainActor
    @Test("Authenticated sessions reject peers that do not support session encryption")
    func missingEncryptionFeatureRejected() async throws {
        let pair = try await makeLoopbackPair(
            clientFeatures: ["loom.handshake.v1", "loom.streams.v1"],
            serverFeatures: ["loom.handshake.v1", "loom.streams.v1"]
        )
        defer {
            Task {
                await pair.stop()
            }
        }

        let clientResult = Task {
            try await pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        }
        let serverResult = Task {
            try await pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager
        )
        }

        await #expect(throws: LoomError.self) {
            _ = try await clientResult.value
        }
        await #expect(throws: LoomError.self) {
            _ = try await serverResult.value
        }
    }

    @MainActor
    @Test("Encrypted authenticated sessions round-trip multiplexed stream payloads")
    func encryptedSessionRoundTrip() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let payload = Data("hello encrypted loom".utf8)
        let outgoingStream = try await pair.client.openStream(label: "roundtrip")
        try await outgoingStream.send(payload)
        try await outgoingStream.close()

        let incomingStream = try #require(await incomingStreamTask.value)
        let receivedPayload = await firstPayload(from: incomingStream)
        #expect(receivedPayload == payload)
    }
}

private struct LoopbackSessionPair {
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
private func makeLoopbackPair(
    clientFeatures: [String] = LoomSessionHelloRequest.defaultFeatures,
    serverFeatures: [String] = LoomSessionHelloRequest.defaultFeatures
) async throws -> LoopbackSessionPair {
    let clientIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.auth-client.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.auth-server.\(UUID().uuidString)",
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
        advertisement: LoomPeerAdvertisement(deviceType: .mac),
        supportedFeatures: clientFeatures
    )
    let serverHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Server",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac),
        supportedFeatures: serverFeatures
    )

    return LoopbackSessionPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        clientHello: clientHello,
        serverHello: serverHello,
        client: client,
        server: server
    )
}

private func firstPayload(from stream: LoomMultiplexedStream) async -> Data? {
    for await payload in stream.incomingBytes {
        return payload
    }
    return nil
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
