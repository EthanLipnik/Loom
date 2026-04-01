//
//  LoomAuthenticatedSessionTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
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

    @MainActor
    @Test("Bootstrap progress observers emit phase transitions through ready")
    func bootstrapProgressObserversEmitPhaseTransitionsThroughReady() async throws {
        let pair = try await makeLoopbackPair()
        defer {
            Task {
                await pair.stop()
            }
        }

        let clientProgressTask = Task<[LoomAuthenticatedSessionBootstrapProgress], Never> {
            let observer = await pair.client.makeBootstrapProgressObserver()
            var events: [LoomAuthenticatedSessionBootstrapProgress] = []
            for await progress in observer {
                if events.last != progress {
                    events.append(progress)
                }
                if progress.phase == .ready {
                    break
                }
            }
            return events
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

        let phases = await clientProgressTask.value.map(\.phase)
        #expect(phases == [.idle, .transportStarting, .transportReady, .localHelloSent, .remoteHelloReceived, .ready])
        #expect(await pair.client.bootstrapProgress == LoomAuthenticatedSessionBootstrapProgress(phase: .ready))
    }

    @MainActor
    @Test("TCP authenticated sessions keep reliable and sendUnreliable payloads coherent")
    func tcpSessionKeepsReliableAndUnreliablePayloadsCoherent() async throws {
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

        let incomingStreamsTask = Task<[LoomMultiplexedStream], Never> {
            var streams: [LoomMultiplexedStream] = []
            for await stream in pair.server.incomingStreams {
                streams.append(stream)
                if streams.count == 2 {
                    return streams
                }
            }
            return streams
        }

        let controlStream = try await pair.client.openStream(label: "control")
        let mediaStream = try await pair.client.openStream(label: "video/1")
        let incomingStreams = await incomingStreamsTask.value
        #expect(incomingStreams.count == 2)
        let serverControlStream = try #require(incomingStreams.first { $0.label == "control" })
        let serverMediaStream = try #require(incomingStreams.first { $0.label == "video/1" })

        let expectedControlPayloads = (0..<8).map { Data("control-\($0)".utf8) }
        let expectedMediaPayloads = (0..<8).map { Data("media-\($0)".utf8) }

        let receivedControlTask = Task {
            await collectPayloads(from: serverControlStream, count: expectedControlPayloads.count)
        }
        let receivedMediaTask = Task {
            await collectPayloads(from: serverMediaStream, count: expectedMediaPayloads.count)
        }

        for index in expectedControlPayloads.indices {
            try await controlStream.send(expectedControlPayloads[index])
            try await mediaStream.sendUnreliable(expectedMediaPayloads[index])
        }
        try await controlStream.close()
        try await mediaStream.close()

        #expect(await receivedControlTask.value == expectedControlPayloads)
        #expect(await receivedMediaTask.value == expectedMediaPayloads)
        #expect(await pair.client.state == .ready)
        #expect(await pair.server.state == .ready)
    }

    @MainActor
    @Test("TCP authenticated sessions keep queued unreliable payloads coherent")
    func tcpSessionKeepsQueuedUnreliablePayloadsCoherent() async throws {
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

        let mediaStream = try await pair.client.openStream(label: "video/queued")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let expectedPayloads = (0 ..< 12).map { Data("queued-media-\($0)".utf8) }
        let completionCount = AsyncBox<Int>()

        let receivedPayloadsTask = Task {
            await collectPayloads(from: serverMediaStream, count: expectedPayloads.count)
        }

        for payload in expectedPayloads {
            mediaStream.sendUnreliableQueued(payload) { error in
                #expect(error == nil)
                Task {
                    await completionCount.increment()
                }
            }
        }

        #expect(await receivedPayloadsTask.value == expectedPayloads)
        let completed = try #require(await completionCount.takeCount(target: expectedPayloads.count, timeoutSeconds: 2.0))
        #expect(completed == expectedPayloads.count)
        try await mediaStream.close()
    }

    @MainActor
    @Test("UDP authenticated sessions buffer out-of-order unreliable data until open")
    func udpSessionBuffersOutOfOrderUnreliableDataUntilOpen() async throws {
        let pair = try await makeStartedUDPLoopbackPair()
        defer {
            Task {
                await pair.stop()
            }
        }

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let expectedPayload = Data("buffered-before-open".utf8)
        try await pair.server.injectUnreliableDataForTesting(
            streamID: 41,
            payload: expectedPayload
        )
        try await pair.server.injectOpenForTesting(streamID: 41, label: "video/buffered")

        let incomingStream = try #require(await incomingStreamTask.value)
        #expect(incomingStream.label == "video/buffered")
        #expect(await firstPayload(from: incomingStream) == expectedPayload)
        #expect(await pair.client.state == .ready)
        #expect(await pair.server.state == .ready)
    }

    @MainActor
    @Test("UDP authenticated sessions keep queued unreliable video payloads coherent on newly opened streams")
    func udpSessionKeepsQueuedUnreliableVideoPayloadsCoherent() async throws {
        let pair = try await makeStartedUDPLoopbackPair()
        defer {
            Task {
                await pair.stop()
            }
        }

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/queued")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let expectedPayloads = (0 ..< 32).map { Data("udp-video-\($0)".utf8) }
        let completionCount = AsyncBox<Int>()

        let receivedPayloadsTask = Task {
            await collectPayloads(from: serverMediaStream, count: expectedPayloads.count)
        }

        for payload in expectedPayloads {
            mediaStream.sendUnreliableQueued(payload) { error in
                #expect(error == nil)
                Task {
                    await completionCount.increment()
                }
            }
        }

        #expect(await receivedPayloadsTask.value == expectedPayloads)
        let completed = try #require(await completionCount.takeCount(target: expectedPayloads.count, timeoutSeconds: 2.0))
        #expect(completed == expectedPayloads.count)
        #expect(await pair.client.state == .ready)
        #expect(await pair.server.state == .ready)
        try await mediaStream.close()
    }

    @MainActor
    @Test("UDP authenticated sessions keep queued unreliable audio payloads coherent on newly opened streams")
    func udpSessionKeepsQueuedUnreliableAudioPayloadsCoherent() async throws {
        let pair = try await makeStartedUDPLoopbackPair()
        defer {
            Task {
                await pair.stop()
            }
        }

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let audioStream = try await pair.client.openStream(label: "audio/queued")
        let serverAudioStream = try #require(await incomingStreamTask.value)
        let expectedPayloads = (0 ..< 24).map { Data("udp-audio-\($0)".utf8) }
        let completionCount = AsyncBox<Int>()

        let receivedPayloadsTask = Task {
            await collectPayloads(from: serverAudioStream, count: expectedPayloads.count)
        }

        for payload in expectedPayloads {
            audioStream.sendUnreliableQueued(payload) { error in
                #expect(error == nil)
                Task {
                    await completionCount.increment()
                }
            }
        }

        #expect(await receivedPayloadsTask.value == expectedPayloads)
        let completed = try #require(await completionCount.takeCount(target: expectedPayloads.count, timeoutSeconds: 2.0))
        #expect(completed == expectedPayloads.count)
        #expect(await pair.client.state == .ready)
        #expect(await pair.server.state == .ready)
        try await audioStream.close()
    }

    @MainActor
    @Test("UDP authenticated session blackhole surfaces a timeout failure")
    func udpBlackholeSurfacesTimeoutFailure() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let readyPort = AsyncBox<UInt16>()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue {
                Task {
                    await readyPort.set(port)
                }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        defer {
            listener.cancel()
        }

        let port = try #require(await readyPort.take())
        let connection = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: port)),
            using: .udp
        )
        let session = LoomAuthenticatedSession(
            rawSession: LoomSession(connection: connection),
            role: .initiator,
            transportKind: .udp
        )
        let progressObserver = await session.makeBootstrapProgressObserver()
        defer {
            Task {
                await session.cancel()
            }
        }

        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.udp-blackhole.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let hello = LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "UDP Client",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(deviceType: .mac)
        )

        do {
            _ = try await session.start(
                localHello: hello,
                identityManager: identityManager
            )
            Issue.record("Expected UDP blackhole session start to fail.")
        } catch let LoomError.connectionFailed(underlying) {
            let failure = LoomConnectionFailure.classify(underlying)
            #expect(failure.reason == .timedOut)
            #expect((failure.errorDescription ?? "").contains("timed out"))
            let progress = await collectBootstrapProgress(
                from: progressObserver,
                throughFailure: true
            )
            let lastProgress = try #require(progress.last)
            #expect(lastProgress.failureReason != nil)
            #expect(lastProgress.phase == .localHelloSent)
        } catch {
            Issue.record("Expected LoomError.connectionFailed, got \(error.localizedDescription).")
        }
    }

    @MainActor
    @Test("Authenticated sessions reject oversized stream labels")
    func oversizedStreamLabelRejected() async throws {
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

        let oversizedLabel = String(
            repeating: "a",
            count: LoomMessageLimits.maxStreamLabelBytes + 1
        )

        do {
            _ = try await pair.client.openStream(label: oversizedLabel)
            Issue.record("Expected an oversized stream label to be rejected.")
        } catch let LoomError.protocolError(message) {
            #expect(message.contains("must not exceed"))
        } catch {
            Issue.record("Expected LoomError.protocolError, got \(error.localizedDescription).")
        }
    }

    @MainActor
    @Test("Authenticated sessions fail explicitly when stream IDs are exhausted")
    func streamIDExhaustionFailsExplicitly() async throws {
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

        await pair.client.setNextOutgoingStreamIDForTesting(UInt16.max)
        _ = try await pair.client.openStream(label: "final-stream")

        do {
            _ = try await pair.client.openStream(label: "wrapped-stream")
            Issue.record("Expected exhausted stream identifiers to fail explicitly.")
        } catch let LoomError.protocolError(message) {
            #expect(message.contains("exhausted"))
        } catch {
            Issue.record("Expected LoomError.protocolError, got \(error.localizedDescription).")
        }
    }

    @MainActor
    @Test("Authenticated sessions expose stable transport metadata")
    func transportMetadataExposed() async throws {
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

        #expect(pair.client.id != pair.server.id)

        let clientRemoteEndpoint = try #require(await pair.client.remoteEndpoint)
        let clientPathSnapshot = try #require(await pair.client.pathSnapshot)
        #expect(clientPathSnapshot.remoteEndpoint == clientRemoteEndpoint)
        #expect(clientPathSnapshot.status == .satisfied)

        if case let .hostPort(host, port) = clientRemoteEndpoint {
            #expect("\(host)" == "127.0.0.1")
            #expect(port.rawValue > 0)
        } else {
            Issue.record("Expected a host/port endpoint for the client transport metadata.")
        }

        let serverRemoteEndpoint = try #require(await pair.server.remoteEndpoint)
        let serverPathSnapshot = try #require(await pair.server.pathSnapshot)
        #expect(serverPathSnapshot.remoteEndpoint == serverRemoteEndpoint)
        #expect(serverPathSnapshot.status == .satisfied)
    }

    @MainActor
    @Test("Authenticated sessions emit the current path snapshot to new observers")
    func pathObserverReceivesInitialSnapshot() async throws {
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

        let expectedSnapshot = try #require(await pair.client.pathSnapshot)
        let observer = await pair.client.makePathObserver()
        let observedSnapshot = try #require(await firstPathSnapshot(from: observer))
        #expect(observedSnapshot == expectedSnapshot)
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

@MainActor
private func makeStartedUDPLoopbackPair(
    clientFeatures: [String] = LoomSessionHelloRequest.defaultFeatures,
    serverFeatures: [String] = LoomSessionHelloRequest.defaultFeatures
) async throws -> LoopbackSessionPair {
    let clientIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.auth-client-udp.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.auth-server-udp.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )

    let listener = try NWListener(using: .udp, on: .any)
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
        using: .udp
    )
    let client = LoomAuthenticatedSession(
        rawSession: LoomSession(connection: clientConnection),
        role: .initiator,
        transportKind: .udp
    )
    let clientHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "UDP Client",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac),
        supportedFeatures: clientFeatures
    )
    let serverHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "UDP Server",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac),
        supportedFeatures: serverFeatures
    )

    let clientStartTask = Task {
        try await client.start(
            localHello: clientHello,
            identityManager: clientIdentityManager
        )
    }

    let serverConnection = try #require(await acceptedConnection.take())
    let server = LoomAuthenticatedSession(
        rawSession: LoomSession(connection: serverConnection),
        role: .receiver,
        transportKind: .udp
    )
    let serverStartTask = Task {
        try await server.start(
            localHello: serverHello,
            identityManager: serverIdentityManager
        )
    }

    _ = try await (clientStartTask.value, serverStartTask.value)

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

private func collectPayloads(
    from stream: LoomMultiplexedStream,
    count: Int
) async -> [Data] {
    var payloads: [Data] = []
    for await payload in stream.incomingBytes {
        payloads.append(payload)
        if payloads.count == count {
            return payloads
        }
    }
    return payloads
}

private func firstPathSnapshot(
    from stream: AsyncStream<LoomSessionNetworkPathSnapshot>
) async -> LoomSessionNetworkPathSnapshot? {
    for await snapshot in stream {
        return snapshot
    }
    return nil
}

private func collectBootstrapProgress(
    from stream: AsyncStream<LoomAuthenticatedSessionBootstrapProgress>,
    throughFailure: Bool = false
) async -> [LoomAuthenticatedSessionBootstrapProgress] {
    var progressEvents: [LoomAuthenticatedSessionBootstrapProgress] = []
    for await progress in stream {
        if progressEvents.last != progress {
            progressEvents.append(progress)
        }
        if progress.phase == .ready || (throughFailure && progress.isFailure) {
            return progressEvents
        }
    }
    return progressEvents
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

    func increment() where Value == Int {
        let nextValue = (value ?? 0) + 1
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume(returning: nextValue)
            return
        }
        value = nextValue
    }

    func takeCount(target: Int, timeoutSeconds: TimeInterval) async -> Int? where Value == Int {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while (value ?? 0) < target, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return value
    }
}
