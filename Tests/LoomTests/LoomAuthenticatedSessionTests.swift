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
    @Test("TCP and QUIC waiting policy fails fast for unreachable POSIX states")
    func framedConnectionWaitingPolicyFailsFastForUnreachableStates() {
        #expect(LoomFramedConnection.shouldFailAfterWaiting(.posix(.ENETDOWN)))
        #expect(LoomFramedConnection.shouldFailAfterWaiting(.posix(.EHOSTUNREACH)))
        #expect(LoomFramedConnection.shouldFailAfterWaiting(.posix(.ENETUNREACH)))
        #expect(LoomFramedConnection.shouldFailAfterWaiting(.posix(.ENOTCONN)))
    }

    @Test("TCP and QUIC waiting policy keeps transient waiting states alive")
    func framedConnectionWaitingPolicyKeepsTransientStatesAlive() {
        #expect(!LoomFramedConnection.shouldFailAfterWaiting(.posix(.ECONNRESET)))
        #expect(!LoomFramedConnection.shouldFailAfterWaiting(.tls(-9807)))
    }

    @Test("Preauthentication admission bounds concurrent handshakes")
    func preauthenticationAdmissionBoundsConcurrentHandshakes() async {
        let admission = LoomPreauthenticationAdmissionController(maxConcurrentConnections: 1)

        #expect(await admission.acquire())
        #expect(!(await admission.acquire()))
        #expect(await admission.activeCount == 1)

        await admission.release()
        #expect(await admission.activeCount == 0)
        #expect(await admission.acquire())
    }

    @MainActor
    @Test("Remote stream opens cannot collide with locally owned identifier parity")
    func remoteStreamOpenRejectsLocalParityCollision() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }
        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        let (establishedClientContext, establishedServerContext) = try await (clientContext, serverContext)
        #expect(establishedClientContext.negotiatedFeatures.contains(LoomSessionHelloRequest.sessionSecurityV2Feature))
        #expect(establishedServerContext.negotiatedFeatures.contains(LoomSessionHelloRequest.sessionSecurityV2Feature))

        let localStream = try await pair.server.openStream(label: "server-owned")
        await #expect(throws: LoomError.self) {
            try await pair.server.injectOpenForTesting(streamID: localStream.id, label: "collision")
        }
        await #expect(throws: LoomError.self) {
            try await pair.server.injectOpenForTesting(streamID: 0, label: "zero")
        }
    }

    @MainActor
    @Test("Authenticated sessions preserve legacy encryption with peers that do not negotiate session security v2")
    func legacyEncryptedSessionCompatibility() async throws {
        let legacyFeatures = LoomSessionHelloRequest.defaultFeatures.filter {
            $0 != LoomSessionHelloRequest.sessionSecurityV2Feature
        }
        let pair = try await makeLoopbackPair(
            clientFeatures: LoomSessionHelloRequest.defaultFeatures,
            serverFeatures: legacyFeatures
        )
        defer { Task { await pair.stop() } }

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        let (establishedClientContext, establishedServerContext) = try await (clientContext, serverContext)

        #expect(!establishedClientContext.negotiatedFeatures.contains(LoomSessionHelloRequest.sessionSecurityV2Feature))
        #expect(!establishedServerContext.negotiatedFeatures.contains(LoomSessionHelloRequest.sessionSecurityV2Feature))
        #expect(establishedClientContext.sessionEncrypted)
        #expect(establishedServerContext.sessionEncrypted)
    }

    @MainActor
    @Test("Remote stream identifiers cannot be opened twice or reused after close")
    func remoteStreamOpenRejectsDuplicateAndReuse() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }

        try await pair.server.injectOpenForTesting(streamID: 41, label: "first")
        await #expect(throws: LoomError.self) {
            try await pair.server.injectOpenForTesting(streamID: 41, label: "duplicate")
        }
        try await pair.server.injectCloseForTesting(streamID: 41)
        await #expect(throws: LoomError.self) {
            try await pair.server.injectOpenForTesting(streamID: 41, label: "reused")
        }
    }

    @MainActor
    @Test("Authenticated sessions cap concurrently retained streams")
    func authenticatedSessionCapsConcurrentStreams() async throws {
        let pair = try await makeLoopbackPair(maximumConcurrentStreams: 2)
        defer { Task { await pair.stop() } }

        try await pair.server.injectOpenForTesting(streamID: 41)
        try await pair.server.injectOpenForTesting(streamID: 43)
        await #expect(throws: LoomError.self) {
            try await pair.server.injectOpenForTesting(streamID: 45)
        }
    }

    @MainActor
    @Test("Authenticated sessions enforce an aggregate incoming byte budget across streams")
    func authenticatedSessionCapsAggregateIncomingBytes() async throws {
        let pair = try await makeLoopbackPair(
            maximumConcurrentStreams: 2,
            maximumBufferedIncomingBytesPerStream: 10,
            maximumBufferedIncomingBytesPerSession: 10
        )
        defer { Task { await pair.stop() } }

        try await pair.server.injectOpenForTesting(streamID: 41)
        try await pair.server.injectOpenForTesting(streamID: 43)
        try await pair.server.injectReliableDataForTesting(
            streamID: 41,
            payload: Data(repeating: 1, count: 6)
        )
        #expect(await pair.server.retainedIncomingBytesForTesting == 6)
        await #expect(throws: LoomError.self) {
            try await pair.server.injectReliableDataForTesting(
                streamID: 43,
                payload: Data(repeating: 2, count: 5)
            )
        }
        #expect(await pair.server.retainedIncomingBytesForTesting == 0)
    }

    @MainActor
    @Test("Unreliable incoming overflow drops payload without failing the session")
    func unreliableIncomingOverflowRemainsStreamScoped() async throws {
        let pair = try await makeLoopbackPair(
            maximumBufferedIncomingBytesPerStream: 16,
            maximumBufferedIncomingPayloadsPerStream: 2,
            maximumBufferedIncomingBytesPerSession: 16
        )
        defer { Task { await pair.stop() } }

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }
        try await pair.server.injectOpenForTesting(streamID: 41, label: "video/test")
        let stream = try #require(await incomingStreamTask.value)

        try await pair.server.injectUnreliableDataForTesting(streamID: 41, payload: Data([1]))
        try await pair.server.injectUnreliableDataForTesting(streamID: 41, payload: Data([2]))
        try await pair.server.injectUnreliableDataForTesting(streamID: 41, payload: Data([3]))

        var iterator = stream.incomingBytes.makeAsyncIterator()
        #expect(await iterator.next() == Data([1]))
        #expect(await iterator.next() == Data([2]))
        try await pair.server.injectUnreliableDataForTesting(streamID: 41, payload: Data([4]))
        #expect(await iterator.next() == Data([4]))
        if case .failed = await pair.server.state {
            Issue.record("Unreliable payload overflow must not fail the authenticated session.")
        }
    }

    @MainActor
    @Test("Authenticated sessions reject empty data envelopes")
    func authenticatedSessionRejectsEmptyDataEnvelope() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }

        try await pair.server.injectOpenForTesting(streamID: 41)
        await #expect(throws: LoomError.self) {
            try await pair.server.injectReliableDataForTesting(
                streamID: 41,
                payload: Data()
            )
        }
    }

    @MainActor
    @Test("Incoming stream notification overflow fails the session closed")
    func incomingStreamNotificationOverflowFailsSession() async throws {
        let pair = try await makeLoopbackPair(maximumConcurrentStreams: 1)
        defer { Task { await pair.stop() } }

        try await pair.server.injectOpenForTesting(streamID: 41)
        try await pair.server.injectCloseForTesting(streamID: 41)
        await #expect(throws: LoomError.self) {
            try await pair.server.injectOpenForTesting(streamID: 43)
        }

        if case .failed = await pair.server.state {
            // Expected fail-closed state.
        } else {
            Issue.record("Expected incoming stream notification overflow to fail the session.")
        }
    }

    @MainActor
    @Test("Failed stream open send removes and finishes the local stream")
    func failedStreamOpenSendCleansUpLocalStream() async throws {
        let pair = try await makeLoopbackPair(maximumConcurrentStreams: 1)
        defer { Task { await pair.stop() } }
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

        let attemptedStream = AsyncBox<LoomMultiplexedStream>()
        await #expect(throws: ForcedOpenSendError.self) {
            _ = try await pair.client.openStreamForTesting(label: "failed-open") { stream in
                await attemptedStream.set(stream)
                throw ForcedOpenSendError.failed
            }
        }

        let failedStream = try #require(await attemptedStream.take())
        var iterator = failedStream.incomingBytes.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await pair.client.activeStreamCountForTesting == 0)

        let replacement = try await pair.client.openStream(label: "replacement")
        #expect(await pair.client.activeStreamCountForTesting == 1)
        try await replacement.close()
    }

    @MainActor
    @Test("Authenticated session handshake deadline cancels a silent peer")
    func handshakeDeadlineCancelsSilentPeer() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }
        _ = try pair.clientIdentityManager.currentIdentity()
        let startedAt = ContinuousClock.now

        await #expect(throws: (any Error).self) {
            try await pair.client.start(
                localHello: pair.clientHello,
                identityManager: pair.clientIdentityManager,
                handshakeTimeout: .milliseconds(100)
            )
        }

        #expect(ContinuousClock.now - startedAt < .seconds(2))
        if case .failed = await pair.client.state {
            // Expected terminal state.
        } else {
            Issue.record("Expected a failed session after the handshake deadline.")
        }
        #expect(await pair.client.bootstrapProgress.failureReason != nil)
    }

    @MainActor
    @Test("Cancelling session start interrupts preauthentication immediately")
    func cancellingSessionStartInterruptsPreauthentication() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }
        _ = try pair.clientIdentityManager.currentIdentity()
        let startTask = Task {
            try await pair.client.start(
                localHello: pair.clientHello,
                identityManager: pair.clientIdentityManager,
                handshakeTimeout: .seconds(30)
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        startTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await startTask.value
        }
        #expect(ContinuousClock.now - cancelledAt < .seconds(2))
    }

    @MainActor
    @Test("Preauthentication deadline does not cancel legitimate delayed trust approval")
    func preauthenticationDeadlineAllowsDelayedTrustApproval() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }
        _ = try pair.clientIdentityManager.currentIdentity()
        _ = try pair.serverIdentityManager.currentIdentity()
        let trustProvider = DelayedTrustProvider(delay: .milliseconds(2_250))

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager,
            handshakeTimeout: .seconds(2)
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: trustProvider,
            handshakeTimeout: .seconds(2)
        )
        _ = try await (clientContext, serverContext)

        #expect(await pair.client.state == .ready)
        #expect(await pair.server.state == .ready)
        #expect(trustProvider.evaluatedPeerCount == 1)
    }

    @MainActor
    @Test("Trust approval deadline cancels evaluation and fails closed")
    func trustApprovalDeadlineCancelsEvaluation() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }
        let trustProvider = CancellationAwareTrustProvider()
        let startedAt = ContinuousClock.now

        let clientTask = Task {
            try await pair.client.start(
                localHello: pair.clientHello,
                identityManager: pair.clientIdentityManager,
                trustTimeout: .milliseconds(100)
            )
        }
        let serverTask = Task {
            try await pair.server.start(
                localHello: pair.serverHello,
                identityManager: pair.serverIdentityManager,
                trustProvider: trustProvider,
                trustTimeout: .milliseconds(100)
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await serverTask.value
        }
        await #expect(throws: (any Error).self) {
            _ = try await clientTask.value
        }
        #expect(ContinuousClock.now - startedAt < .seconds(5))
        for _ in 0 ..< 20 where !trustProvider.didObserveCancellation {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(trustProvider.didObserveCancellation)
    }

    @MainActor
    @Test("Shared preauthentication limiter bounds cancellation-insensitive trust across sessions")
    func sharedPreauthenticationLimiterBoundsStuckTrust() async throws {
        let limiter = LoomOutstandingOperationLimiter(maximumConcurrentOperations: 1)
        let provider = CancellationInsensitiveTrustProvider()
        let firstPair = try await makeLoopbackPair()
        defer { Task { await firstPair.stop() } }
        _ = try firstPair.clientIdentityManager.currentIdentity()
        _ = try firstPair.serverIdentityManager.currentIdentity()
        await firstPair.server.setPreauthenticationOperationLimiter(limiter)

        let firstClientStart = Task {
            try await firstPair.client.start(
                localHello: firstPair.clientHello,
                identityManager: firstPair.clientIdentityManager
            )
        }
        let firstServerStart = Task {
            try await firstPair.server.start(
                localHello: firstPair.serverHello,
                identityManager: firstPair.serverIdentityManager,
                trustProvider: provider,
                trustTimeout: .milliseconds(50)
            )
        }
        await provider.waitUntilStarted()
        do {
            _ = try await firstServerStart.value
            Issue.record("Expected the first trust evaluation to time out.")
        } catch {}
        do {
            _ = try await firstClientStart.value
            Issue.record("Expected the first peer to observe session failure.")
        } catch {}
        #expect(await limiter.activeCount == 1)

        let secondPair = try await makeLoopbackPair()
        defer { Task { await secondPair.stop() } }
        _ = try secondPair.clientIdentityManager.currentIdentity()
        _ = try secondPair.serverIdentityManager.currentIdentity()
        await secondPair.server.setPreauthenticationOperationLimiter(limiter)
        let secondStartedAt = ContinuousClock.now
        async let secondClientStart = secondPair.client.start(
            localHello: secondPair.clientHello,
            identityManager: secondPair.clientIdentityManager
        )
        async let secondServerStart = secondPair.server.start(
            localHello: secondPair.serverHello,
            identityManager: secondPair.serverIdentityManager,
            trustProvider: provider,
            trustTimeout: .milliseconds(50)
        )
        do {
            _ = try await (secondClientStart, secondServerStart)
            Issue.record("Expected the shared limiter to reject the second preauthentication operation.")
        } catch {}
        #expect(ContinuousClock.now - secondStartedAt < .seconds(2))
        #expect(await limiter.activeCount == 1)

        provider.release()
        let releaseDeadline = ContinuousClock.now + .seconds(1)
        while await limiter.activeCount != 0,
              ContinuousClock.now < releaseDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await limiter.activeCount == 0)
    }

    @Test("Closing stream finalizes local state when remote close throws")
    func streamCloseFinalizesLocalStateWhenRemoteCloseThrows() async {
        let recorder = ThrowingStreamCloseRecorder()
        let stream = LoomMultiplexedStream(
            id: 1,
            label: "throwing-close",
            sendHandler: { _ in },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, _, onComplete in
                onComplete(nil)
            },
            queuedUnreliableResetHandler: { _ in },
            closeHandler: {
                try await recorder.close()
            }
        )
        let inboundFinished = Task<Bool, Never> {
            var iterator = stream.incomingBytes.makeAsyncIterator()
            return await iterator.next() == nil
        }

        await #expect(throws: ThrowingStreamCloseError.self) {
            try await stream.close()
        }
        #expect(await inboundFinished.value)

        try? await stream.close()
        #expect(await recorder.attemptCount == 1)
    }

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
    @Test("Authenticated sessions fail closed when trust requires approval")
    func requiresApprovalTrustOutcomeFailsClosed() async throws {
        try await assertTrustOutcomeFailsClosed(
            LoomTrustEvaluation(decision: .requiresApproval, shouldShowAutoTrustNotice: false)
        )
    }

    @MainActor
    @Test("Authenticated sessions fail closed when trust is unavailable")
    func unavailableTrustOutcomeFailsClosed() async throws {
        try await assertTrustOutcomeFailsClosed(
            LoomTrustEvaluation(decision: .unavailable("iCloud not available"), shouldShowAutoTrustNotice: false)
        )
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
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
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
        let trustProvider = DelayedTrustProvider(delay: .milliseconds(750))
        defer {
            Task {
                await pair.stop()
            }
        }

        let observer = await pair.client.makeBootstrapProgressObserver()

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: trustProvider
        )
        _ = try await (clientContext, serverContext)

        var events: [LoomAuthenticatedSessionBootstrapProgress] = []
        for await progress in observer {
            if events.last != progress {
                events.append(progress)
            }
            if progress.phase == .ready {
                break
            }
        }
        let phases = events.map(\.phase)
        #expect(phases == [
            .idle,
            .transportStarting,
            .transportReady,
            .localHelloSent,
            .remoteHelloReceived,
            .trustPendingApproval,
            .ready,
        ])
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
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
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
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
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
    @Test("TCP authenticated sessions reject proximity realtime display queued unreliable sends")
    func tcpSessionRejectsProximityRealtimeDisplayQueuedUnreliableSends() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/awdl-realtime")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let completionError = AsyncBox<LoomQueuedUnreliableSendDrop>()
        mediaStream.sendUnreliableQueued(
            Data("must-not-use-tcp".utf8),
            profile: .proximityRealtimeDisplay,
            options: LoomQueuedUnreliableSendOptions(
                importance: .realtimeInterFrame,
                frameID: 42,
                fragmentIndex: 1,
                fragmentCount: 3
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop {
                Task {
                    await completionError.set(drop)
                }
            }
        }

        let drop = try #require(await completionError.take(timeoutSeconds: 2.0))
        #expect(drop.reason == .unsupportedTransport)
        #expect(drop.profile == .proximityRealtimeDisplay)
        #expect(drop.frameID == 42)
        #expect(drop.fragmentIndex == 1)
        #expect(drop.fragmentCount == 3)
        #expect(await collectPayloads(from: serverMediaStream, count: 1, timeoutSeconds: 0.1) == nil)
        try await mediaStream.close()
    }

    @MainActor
    @Test("Batched stream handler preserves queued unreliable payload order")
    func batchedStreamHandlerPreservesQueuedUnreliablePayloadOrder() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/batched")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let collector = BatchedPayloadCollector(targetCount: 12)
        serverMediaStream.setIncomingBytesBatchHandler(
            maxBatchSize: 4,
            maxDelay: .milliseconds(25)
        ) { batch in
            await collector.append(batch)
        }

        let expectedPayloads = (0 ..< 12).map { Data("batched-media-\($0)".utf8) }
        for payload in expectedPayloads {
            mediaStream.sendUnreliableQueued(payload)
        }

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 2.0))
        #expect(receivedPayloads == expectedPayloads)
        try await mediaStream.close()
    }

    @MainActor
    @Test("Batched stream handler flushes partial batch before close")
    func batchedStreamHandlerFlushesPartialBatchBeforeClose() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/batched-partial")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let collector = BatchedPayloadCollector(targetCount: 3)
        serverMediaStream.setIncomingBytesBatchHandler(
            maxBatchSize: 16,
            maxDelay: .seconds(5)
        ) { batch in
            await collector.append(batch)
        }

        let expectedPayloads = (0 ..< 3).map { Data("partial-batch-\($0)".utf8) }
        for payload in expectedPayloads {
            try await mediaStream.sendUnreliable(payload)
        }
        try await mediaStream.close()

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 2.0))
        #expect(receivedPayloads == expectedPayloads)
    }

    @MainActor
    @Test("Batched stream handler can deliver immediately without timer flush")
    func batchedStreamHandlerCanDeliverImmediatelyWithoutTimerFlush() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/batched-immediate")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let collector = BatchedPayloadCollector(targetCount: 1)
        serverMediaStream.setIncomingBytesBatchHandler(
            maxBatchSize: 16,
            maxDelay: .zero
        ) { batch in
            await collector.append(batch)
        }

        let payload = Data("immediate-batch".utf8)
        try await mediaStream.sendUnreliable(payload)

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 0.25))
        #expect(receivedPayloads == [payload])
        try await mediaStream.close()
    }

    @MainActor
    @Test("Immediate batch handler honors max batch size and preserves order")
    func immediateBatchHandlerHonorsMaxBatchSizeAndPreservesOrder() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/immediate-batch")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let collector = SynchronousBatchedPayloadCollector(targetCount: 8)
        serverMediaStream.setIncomingBytesImmediateBatchHandler(maxBatchSize: 4) { batch in
            collector.append(batch)
        }

        let expectedPayloads = (0 ..< 8).map { Data("immediate-media-\($0)".utf8) }
        for payload in expectedPayloads {
            try await mediaStream.sendUnreliable(payload)
        }

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 0.5))
        #expect(receivedPayloads == expectedPayloads)
        #expect(collector.maxBatchSizeSnapshot() <= 4)
        try await mediaStream.close()
    }

    @MainActor
    @Test("Immediate batch handler flushes before stream close")
    func immediateBatchHandlerFlushesBeforeStreamClose() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/immediate-close")
        let serverMediaStream = try #require(await incomingStreamTask.value)
        let collector = SynchronousBatchedPayloadCollector(targetCount: 3)
        serverMediaStream.setIncomingBytesImmediateBatchHandler(maxBatchSize: 16) { batch in
            collector.append(batch)
        }

        let expectedPayloads = (0 ..< 3).map { Data("immediate-close-\($0)".utf8) }
        for payload in expectedPayloads {
            try await mediaStream.sendUnreliable(payload)
        }
        try await mediaStream.close()

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 0.5))
        #expect(receivedPayloads == expectedPayloads)
    }

    @Test("Batch dispatcher finish prevents late scheduled flush callbacks")
    func batchDispatcherFinishPreventsLateScheduledFlushCallbacks() async throws {
        let collector = BatchedPayloadCollector(targetCount: 1)
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 16,
            maxDelay: .milliseconds(100)
        ) { batch in
            await collector.append(batch)
        }

        let deliveredPayload = Data("finish-flush".utf8)
        dispatcher.yield(deliveredPayload)
        dispatcher.finish()
        dispatcher.yield(Data("after-finish".utf8))

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 0.5))
        #expect(receivedPayloads == [deliveredPayload])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await collector.payloadSnapshot() == [deliveredPayload])
    }

    @Test("Inbound delivery retries the replacement for a concurrently retired batch handler")
    func inboundDeliveryRetriesReplacementBatchHandler() async throws {
        let stream = makeTestMultiplexedStream(maximumBufferedIncomingBytes: 100)
        let collector = SynchronousBatchedPayloadCollector(targetCount: 1)
        stream.setIncomingBytesImmediateBatchHandler(maxBatchSize: 1) { batch in
            collector.append(batch)
        }

        let retiredDispatcher = LoomIncomingByteBatchDispatcher(maxBatchSize: 1) { _ in }
        retiredDispatcher.finish()
        let payload = Data("replacement-race".utf8)

        #expect(stream.yieldForTesting(payload, initiallyUsing: retiredDispatcher))
        let delivered = try #require(await collector.payloads(timeoutSeconds: 0.5))
        #expect(delivered == [payload])
        stream.abortInbound()
    }

    @Test("Async handler replacements share one retained-capacity budget")
    func asyncHandlerReplacementsShareRetainedCapacityBudget() async throws {
        let oldHandler = BlockingBatchHandler()
        let newCollector = BatchedPayloadCollector(targetCount: 1)
        let overflowCount = SynchronousCounter()
        let stream = makeTestMultiplexedStream(
            maximumBufferedIncomingBytes: 10,
            onIncomingBufferOverflow: {
                overflowCount.increment()
            }
        )
        stream.setIncomingBytesBatchHandler(maxBatchSize: 1, maxDelay: .zero) { batch in
            await oldHandler.handle(batch)
        }
        #expect(stream.yield(Data(repeating: 1, count: 6)))
        await oldHandler.waitUntilStarted()

        stream.setIncomingBytesBatchHandler(maxBatchSize: 1, maxDelay: .zero) { batch in
            await newCollector.append(batch)
        }
        #expect(stream.retainedIncomingBatchBytesForTesting == 6)
        #expect(!stream.yield(Data(repeating: 2, count: 5)))
        #expect(overflowCount.value == 1)

        await oldHandler.release()
        let deadline = ContinuousClock.now + .seconds(1)
        while stream.retainedIncomingBatchBytesForTesting != 0,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(stream.retainedIncomingBatchBytesForTesting == 0)

        let payload = Data(repeating: 3, count: 5)
        #expect(stream.yield(payload))
        let delivered = try #require(await newCollector.payloads(timeoutSeconds: 0.5))
        #expect(delivered == [payload])
        stream.abortInbound()
    }

    @Test("Default and batched delivery modes share one retained-capacity budget")
    func defaultAndBatchModesShareRetainedCapacityBudget() async throws {
        let collector = BatchedPayloadCollector(targetCount: 1)
        let overflowCount = SynchronousCounter()
        let stream = makeTestMultiplexedStream(
            maximumBufferedIncomingBytes: 10,
            onIncomingBufferOverflow: {
                overflowCount.increment()
            }
        )
        let defaultPayload = Data(repeating: 1, count: 6)
        #expect(stream.yield(defaultPayload))
        stream.setIncomingBytesBatchHandler(maxBatchSize: 1, maxDelay: .zero) { batch in
            await collector.append(batch)
        }

        #expect(stream.retainedIncomingBatchBytesForTesting == 6)
        #expect(!stream.yield(Data(repeating: 2, count: 5)))
        #expect(overflowCount.value == 1)

        var iterator = stream.incomingBytes.makeAsyncIterator()
        #expect(await iterator.next() == defaultPayload)
        #expect(stream.retainedIncomingBatchBytesForTesting == 0)

        let batchedPayload = Data(repeating: 3, count: 5)
        #expect(stream.yield(batchedPayload))
        let delivered = try #require(await collector.payloads(timeoutSeconds: 0.5))
        #expect(delivered == [batchedPayload])
        stream.abortInbound()
    }

    @Test("Batch dispatcher flushes partial batch after max delay")
    func batchDispatcherFlushesPartialBatchAfterMaxDelay() async throws {
        let collector = BatchedPayloadCollector(targetCount: 1)
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 16,
            maxDelay: .milliseconds(10)
        ) { batch in
            await collector.append(batch)
        }

        let payload = Data("timed-partial-flush".utf8)
        dispatcher.yield(payload)

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 0.5))
        #expect(receivedPayloads == [payload])
        dispatcher.finish()
    }

    @Test("Default stream delivery enforces a byte budget")
    func defaultStreamDeliveryEnforcesByteBudget() async throws {
        #expect(
            LoomNetworkConfiguration().maximumBufferedIncomingBytesPerStream ==
                LoomMessageLimits.maxReceiveBufferBytes
        )
        let overflowCount = SynchronousCounter()
        let stream = makeTestMultiplexedStream(
            maximumBufferedIncomingBytes: 10,
            onIncomingBufferOverflow: {
                overflowCount.increment()
            }
        )

        #expect(stream.yield(Data(repeating: 1, count: 6)))
        #expect(!stream.yield(Data(repeating: 2, count: 5)))
        #expect(overflowCount.value == 1)

        var iterator = stream.incomingBytes.makeAsyncIterator()
        #expect(await iterator.next() == Data(repeating: 1, count: 6))
        #expect(stream.yield(Data(repeating: 3, count: 5)))
        #expect(await iterator.next() == Data(repeating: 3, count: 5))
        #expect(!stream.yield(Data(repeating: 4, count: 11)))
        #expect(overflowCount.value == 1)
        stream.finishInbound()
    }

    @Test("Default stream delivery rejects empty payloads and caps retained items")
    func defaultStreamDeliveryCapsItems() async {
        let overflowCount = SynchronousCounter()
        let stream = makeTestMultiplexedStream(
            maximumBufferedIncomingBytes: 100,
            maximumBufferedIncomingPayloads: 2,
            onIncomingBufferOverflow: {
                overflowCount.increment()
            }
        )

        #expect(!stream.yield(Data()))
        #expect(stream.yield(Data([1])))
        #expect(stream.yield(Data([2])))
        #expect(!stream.yield(Data([3])))
        #expect(overflowCount.value == 1)
        stream.abortInbound()
    }

    @Test("Graceful inbound finish drains accepted default payloads")
    func gracefulInboundFinishDrainsAcceptedPayloads() async {
        let stream = makeTestMultiplexedStream(maximumBufferedIncomingBytes: 100)
        #expect(stream.yield(Data([1])))
        #expect(stream.yield(Data([2])))
        stream.finishInbound()

        var iterator = stream.incomingBytes.makeAsyncIterator()
        #expect(await iterator.next() == Data([1]))
        #expect(await iterator.next() == Data([2]))
        #expect(await iterator.next() == nil)
    }

    @Test("Async batch dispatcher counts in-flight bytes and reports overflow")
    func asyncBatchDispatcherCountsInFlightBytes() async {
        let handler = BlockingBatchHandler()
        let overflowCount = SynchronousCounter()
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 1,
            maxDelay: .zero,
            maximumBufferedBytes: 10,
            onOverflow: {
                overflowCount.increment()
            }
        ) { batch in
            await handler.handle(batch)
        }

        #expect(dispatcher.yield(Data(repeating: 1, count: 6)))
        await handler.waitUntilStarted()
        #expect(!dispatcher.yield(Data(repeating: 2, count: 5)))
        #expect(overflowCount.value == 1)

        await handler.release()
        dispatcher.finish()
    }

    @Test("Async batch dispatcher rejects one oversized payload")
    func asyncBatchDispatcherRejectsOversizedPayload() async {
        let handler = BlockingBatchHandler()
        let overflowCount = SynchronousCounter()
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 1,
            maxDelay: .zero,
            maximumBufferedBytes: 10,
            onOverflow: {
                overflowCount.increment()
            }
        ) { batch in
            await handler.handle(batch)
        }

        #expect(!dispatcher.yield(Data(repeating: 1, count: 11)))
        #expect(overflowCount.value == 1)
        #expect(await handler.batchCount == 0)
        dispatcher.finish()
    }

    @Test("Async batch dispatcher caps retained payload and batch counts")
    func asyncBatchDispatcherCapsPayloadAndBatchCounts() async {
        let partialDispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 10,
            maxDelay: .seconds(1),
            maximumBufferedBytes: 100,
            maximumBufferedPayloadCount: 2,
            maximumBufferedBatchCount: 10
        ) { _ in }
        #expect(partialDispatcher.yield(Data([1])))
        #expect(partialDispatcher.yield(Data([2])))
        #expect(!partialDispatcher.yield(Data([3])))
        partialDispatcher.abort()

        let handler = BlockingBatchHandler()
        let batchDispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 1,
            maxDelay: .zero,
            maximumBufferedBytes: 100,
            maximumBufferedPayloadCount: 10,
            maximumBufferedBatchCount: 1
        ) { batch in
            await handler.handle(batch)
        }
        #expect(batchDispatcher.yield(Data([1])))
        await handler.waitUntilStarted()
        #expect(!batchDispatcher.yield(Data([2])))
        batchDispatcher.abort()
        await handler.release()
    }

    @Test("Aborting async batch delivery drops queued payloads")
    func abortingAsyncBatchDeliveryDropsQueuedPayloads() async {
        let handler = BlockingBatchHandler()
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 1,
            maxDelay: .zero,
            maximumBufferedBytes: 100
        ) { batch in
            await handler.handle(batch)
        }
        #expect(dispatcher.yield(Data([1])))
        await handler.waitUntilStarted()
        #expect(dispatcher.yield(Data([2])))

        dispatcher.abort()
        await handler.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await handler.batchCount == 1)
    }

    @Test("Immediate batch dispatcher flushes synchronously within its byte budget")
    func immediateBatchDispatcherPreservesSynchronousDelivery() {
        let collector = SynchronousBatchedPayloadCollector(targetCount: 2)
        let overflowCount = SynchronousCounter()
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: 2,
            maximumBufferedBytes: 10,
            onOverflow: {
                overflowCount.increment()
            }
        ) { batch in
            collector.append(batch)
        }

        let firstPayload = Data(repeating: 1, count: 6)
        let secondPayload = Data(repeating: 2, count: 5)
        #expect(dispatcher.yield(firstPayload))
        #expect(dispatcher.yield(secondPayload))
        #expect(collector.payloadSnapshot() == [firstPayload])
        #expect(overflowCount.value == 0)

        dispatcher.finish()
        #expect(collector.payloadSnapshot() == [firstPayload, secondPayload])
    }

    @MainActor
    @Test("Async incoming handler overflow fails the authenticated session")
    func asyncIncomingHandlerOverflowFailsSession() async throws {
        let pair = try await makeLoopbackPair(maximumBufferedIncomingBytesPerStream: 12)
        let handler = BlockingBatchHandler()
        defer {
            Task {
                await handler.release()
                await pair.stop()
            }
        }

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }
        try await pair.server.injectOpenForTesting(streamID: 41)
        let stream = try #require(await incomingStreamTask.value)
        stream.setIncomingBytesBatchHandler(maxBatchSize: 1, maxDelay: .zero) { batch in
            await handler.handle(batch)
        }

        try await pair.server.injectReliableDataForTesting(
            streamID: 41,
            payload: Data(repeating: 1, count: 4)
        )
        await handler.waitUntilStarted()
        try await pair.server.injectReliableDataForTesting(
            streamID: 41,
            payload: Data(repeating: 2, count: 4)
        )
        await #expect(throws: LoomError.self) {
            try await pair.server.injectReliableDataForTesting(
                streamID: 41,
                payload: Data(repeating: 3, count: 5)
            )
        }
        await waitUntilSessionFinished(pair.server)
        if case .failed = await pair.server.state {
            // Expected fail-closed state.
        } else {
            Issue.record("Expected incoming byte overflow to fail the session.")
        }
        await handler.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await handler.batchCount == 1)
    }

    @Test("Immediate batch dispatcher honors max batch size")
    func immediateBatchDispatcherHonorsMaxBatchSize() async throws {
        let collector = SynchronousBatchedPayloadCollector(targetCount: 8)
        let dispatcher = LoomIncomingByteBatchDispatcher(maxBatchSize: 4) { batch in
            collector.append(batch)
        }

        let expectedPayloads = (0 ..< 8).map { Data("direct-immediate-\($0)".utf8) }
        for payload in expectedPayloads {
            dispatcher.yield(payload)
        }

        let receivedPayloads = try #require(await collector.payloads(timeoutSeconds: 0.5))
        #expect(receivedPayloads == expectedPayloads)
        #expect(collector.maxBatchSizeSnapshot() == 4)
        dispatcher.finish()
    }

    @MainActor
    @Test("TCP authenticated sessions ignore late queued payloads after a stream closes")
    func tcpSessionIgnoresLateQueuedPayloadsAfterClose() async throws {
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

        let incomingStreamTask = Task<LoomMultiplexedStream?, Never> {
            for await stream in pair.server.incomingStreams {
                return stream
            }
            return nil
        }

        let mediaStream = try await pair.client.openStream(label: "video/late-after-close")
        _ = try #require(await incomingStreamTask.value)

        try await pair.client.injectCloseForTesting(streamID: mediaStream.id)
        try await pair.client.injectReliableDataForTesting(
            streamID: mediaStream.id,
            payload: Data("late-after-close".utf8)
        )

        #expect(await pair.client.state == .ready)
        #expect(await pair.server.state == .ready)
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
        await #expect(throws: LoomError.self) {
            try await pair.server.injectUnreliableDataForTesting(
                streamID: 0,
                payload: expectedPayload
            )
        }
        await #expect(throws: LoomError.self) {
            try await pair.server.injectUnreliableDataForTesting(
                streamID: 42,
                payload: expectedPayload
            )
        }
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

    @Test("Buffered pre-open unreliable payloads expire without later traffic")
    func preOpenUnreliablePayloadsExpireIndependently() async throws {
        let port = try #require(NWEndpoint.Port(rawValue: 9))
        let session = LoomAuthenticatedSession(
            connection: .udp(NWConnection(host: "127.0.0.1", port: port, using: .udp)),
            role: .receiver
        )
        let parentBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 128,
            maximumPayloadCount: 8,
            maximumBatchCount: 8
        )
        #expect(session.setParentIncomingRetainedCapacityBudget(parentBudget))
        defer { Task { await session.cancel() } }

        try await session.injectUnreliableDataForTesting(
            streamID: 41,
            payload: Data(repeating: 1, count: 16)
        )
        #expect(parentBudget.retainedBytesForTesting == 16)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(parentBudget.retainedBytesForTesting == 0)
    }

    @Test("Pre-open unreliable payload count cannot exceed the destination stream limit")
    func preOpenPayloadsRespectDestinationStreamLimit() async throws {
        let port = try #require(NWEndpoint.Port(rawValue: 9))
        let session = LoomAuthenticatedSession(
            connection: .udp(NWConnection(host: "127.0.0.1", port: port, using: .udp)),
            role: .receiver,
            maximumBufferedIncomingBytesPerStream: 64,
            maximumBufferedIncomingPayloadsPerStream: 2,
            maximumBufferedIncomingBytesPerSession: 64,
            maximumBufferedIncomingPayloadsPerSession: 4
        )
        let parentBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 64,
            maximumPayloadCount: 4,
            maximumBatchCount: 4
        )
        #expect(session.setParentIncomingRetainedCapacityBudget(parentBudget))
        defer { Task { await session.cancel() } }

        try await session.injectUnreliableDataForTesting(streamID: 41, payload: Data([1]))
        try await session.injectUnreliableDataForTesting(streamID: 41, payload: Data([2]))
        #expect(parentBudget.retainedBytesForTesting == 2)
        try await session.injectUnreliableDataForTesting(streamID: 41, payload: Data([3]))
        #expect(parentBudget.retainedBytesForTesting == 0)
    }

    @Test("Pre-retained payloads coalesce into a batch without leaking hierarchy capacity")
    func preRetainedPayloadsCoalesceWithoutBudgetLeak() async throws {
        let parentBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 16,
            maximumPayloadCount: 3,
            maximumBatchCount: 3
        )
        let streamBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 16,
            maximumPayloadCount: 3,
            maximumBatchCount: 3,
            parent: parentBudget
        )
        let stream = LoomMultiplexedStream(
            id: 41,
            label: "pre-retained-batch",
            sendHandler: { _ in },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, _, onComplete in onComplete(nil) },
            queuedUnreliableResetHandler: { _ in },
            maximumBufferedIncomingBytes: 16,
            maximumBufferedIncomingPayloads: 3,
            incomingRetainedCapacityBudget: streamBudget,
            closeHandler: {}
        )
        let collector = SynchronousBatchedPayloadCollector(targetCount: 3)
        stream.setIncomingBytesImmediateBatchHandler(maxBatchSize: 3) { batch in
            collector.append(batch)
        }
        let payloads = [Data([1]), Data([2]), Data([3])]
        for payload in payloads {
            #expect(streamBudget.reserve(bytes: payload.count, payloadCount: 1, startsNewBatch: true))
            #expect(stream.yieldPreRetained(payload))
        }

        #expect(try #require(await collector.payloads(timeoutSeconds: 0.25)) == payloads)
        #expect(parentBudget.retainedBytesForTesting == 0)
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
    @Test("UDP authenticated sessions ignore late unreliable payloads after a stream closes")
    func udpSessionIgnoresLateUnreliablePayloadsAfterClose() async throws {
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

        let mediaStream = try await pair.client.openStream(label: "video/late-after-close")
        _ = try #require(await incomingStreamTask.value)

        try await pair.client.injectCloseForTesting(streamID: mediaStream.id)
        try await pair.client.injectUnreliableDataForTesting(
            streamID: mediaStream.id,
            payload: Data("late-after-close".utf8)
        )

        #expect(await pair.client.state == .ready)
        #expect(await pair.server.state == .ready)
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
            connection: .udp(connection),
            role: .initiator
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
    @Test("UDP handshake ignores stale reliable payload before valid hello")
    func udpHandshakeIgnoresStaleReliablePayloadBeforeValidHello() async throws {
        let serverIdentityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.udp-stale-server.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let serverHello = try LoomSessionHelloValidator.makeSignedHello(
            from: LoomSessionHelloRequest(
                deviceID: UUID(),
                deviceName: "UDP Server",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement(deviceType: .mac),
                supportedFeatures: LoomSessionHelloRequest.defaultFeatures.filter {
                    $0 != LoomSessionHelloRequest.sessionSecurityV2Feature
                }
            ),
            identityManager: serverIdentityManager
        )
        let serverHelloPayload = try JSONEncoder().encode(serverHello)
        let trustedPayload = try JSONEncoder().encode(LoomHandshakeTrustStatus.trusted)
        let listener = try NWListener(using: .udp, on: .any)
        let readyPort = AsyncBox<UInt16>()

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receiveMessage { _, _, _, _ in
                sendReliableDatagram(
                    Data("stale multiplexed stream payload".utf8),
                    sequence: 7,
                    flags: .reliable,
                    over: connection
                )
                sendReliableDatagram(
                    serverHelloPayload,
                    sequence: 0,
                    flags: [.reliable, .hello],
                    over: connection
                )
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    sendReliableDatagram(
                        trustedPayload,
                        sequence: 1,
                        flags: .reliable,
                        over: connection
                    )
                }
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
            connection: .udp(connection),
            role: .initiator
        )
        let progressObserver = await session.makeBootstrapProgressObserver()
        defer {
            Task {
                await session.cancel()
            }
        }

        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.udp-stale-client.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let hello = LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "UDP Client",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(deviceType: .mac)
        )

        let context = try await session.start(
            localHello: hello,
            identityManager: identityManager
        )
        #expect(context.peerIdentity.name == "UDP Server")
        #expect(context.transportKind == .udp)

        let progress = await collectBootstrapProgress(
            from: progressObserver,
            throughFailure: true
        )
        #expect(progress.map(\.phase).contains(.ready))
    }

    @MainActor
    @Test("Malformed UDP session hello fails as transport loss")
    func malformedUDPSessionHelloFailsAsTransportLoss() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let readyPort = AsyncBox<UInt16>()

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receiveMessage { _, _, _, _ in
                sendReliableDatagram(
                    Data("not a signed Loom hello".utf8),
                    sequence: 0,
                    flags: [.reliable, .hello],
                    over: connection
                )
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
            connection: .udp(connection),
            role: .initiator
        )
        let progressObserver = await session.makeBootstrapProgressObserver()
        defer {
            Task {
                await session.cancel()
            }
        }

        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.udp-malformed-hello.\(UUID().uuidString)",
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
            Issue.record("Expected malformed UDP hello to fail.")
        } catch let LoomError.connectionFailed(underlying) {
            let failure = LoomConnectionFailure.classify(underlying)
            #expect(failure.reason == .transportLoss)
            #expect((failure.errorDescription ?? "").contains("malformed Loom session hello"))
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
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
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
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
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
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
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
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        _ = try await (clientContext, serverContext)

        let expectedSnapshot = try #require(await pair.client.pathSnapshot)
        let observer = await pair.client.makePathObserver()
        let observedSnapshot = try #require(await firstPathSnapshot(from: observer))
        #expect(observedSnapshot == expectedSnapshot)
    }
}

private enum ThrowingStreamCloseError: Error {
    case closeFailed
}

private enum ForcedOpenSendError: Error {
    case failed
}

private actor ThrowingStreamCloseRecorder {
    private(set) var attemptCount = 0

    func close() throws {
        attemptCount += 1
        throw ThrowingStreamCloseError.closeFailed
    }
}

private struct LoopbackSessionPair {
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
private func makeLoopbackPair(
    clientFeatures: [String] = LoomSessionHelloRequest.defaultFeatures,
    serverFeatures: [String] = LoomSessionHelloRequest.defaultFeatures,
    maximumConcurrentStreams: Int = 256,
    maximumBufferedIncomingBytesPerStream: Int = LoomMessageLimits.maxReceiveBufferBytes,
    maximumBufferedIncomingPayloadsPerStream: Int = LoomMessageLimits.maxBufferedPayloadsPerStream,
    maximumBufferedIncomingBytesPerSession: Int = LoomMessageLimits.maxBufferedIncomingBytesPerSession
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
        connection: .tcp(clientConnection),
        role: .initiator,
        maximumConcurrentStreams: maximumConcurrentStreams,
        maximumBufferedIncomingBytesPerStream: maximumBufferedIncomingBytesPerStream,
        maximumBufferedIncomingPayloadsPerStream: maximumBufferedIncomingPayloadsPerStream,
        maximumBufferedIncomingBytesPerSession: maximumBufferedIncomingBytesPerSession
    )
    let server = LoomAuthenticatedSession(
        connection: .tcp(serverConnection),
        role: .receiver,
        maximumConcurrentStreams: maximumConcurrentStreams,
        maximumBufferedIncomingBytesPerStream: maximumBufferedIncomingBytesPerStream,
        maximumBufferedIncomingPayloadsPerStream: maximumBufferedIncomingPayloadsPerStream,
        maximumBufferedIncomingBytesPerSession: maximumBufferedIncomingBytesPerSession
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
    let serverTrustProvider = AlwaysTrustProvider()

    return LoopbackSessionPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        serverTrustProvider: serverTrustProvider,
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
        connection: .udp(clientConnection),
        role: .initiator
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
    let serverTrustProvider = AlwaysTrustProvider()

    let clientStartTask = Task {
        try await client.start(
            localHello: clientHello,
            identityManager: clientIdentityManager
        )
    }

    let serverConnection = try #require(await acceptedConnection.take())
    let server = LoomAuthenticatedSession(
        connection: .udp(serverConnection),
        role: .receiver
    )
    let serverStartTask = Task {
        try await server.start(
            localHello: serverHello,
            identityManager: serverIdentityManager,
            trustProvider: serverTrustProvider
        )
    }

    _ = try await (clientStartTask.value, serverStartTask.value)

    return LoopbackSessionPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        serverTrustProvider: serverTrustProvider,
        clientHello: clientHello,
        serverHello: serverHello,
        client: client,
        server: server
    )
}

private func makeTestMultiplexedStream(
    maximumBufferedIncomingBytes: Int,
    maximumBufferedIncomingPayloads: Int = LoomMessageLimits.maxBufferedPayloadsPerStream,
    onIncomingBufferOverflow: @escaping @Sendable () -> Void = {}
) -> LoomMultiplexedStream {
    LoomMultiplexedStream(
        id: 1,
        label: "test",
        sendHandler: { _ in },
        unreliableSendHandler: { _ in },
        queuedUnreliableSendHandler: { _, _, _, onComplete in
            onComplete(nil)
        },
        queuedUnreliableResetHandler: { _ in },
        maximumBufferedIncomingBytes: maximumBufferedIncomingBytes,
        maximumBufferedIncomingPayloads: maximumBufferedIncomingPayloads,
        onIncomingBufferOverflow: onIncomingBufferOverflow,
        closeHandler: {}
    )
}

private func firstPayload(from stream: LoomMultiplexedStream) async -> Data? {
    for await payload in stream.incomingBytes {
        return payload
    }
    return nil
}

private func sendReliableDatagram(
    _ payload: Data,
    sequence: UInt32,
    flags: LoomReliablePacketFlags,
    over connection: NWConnection
) {
    let header = LoomReliablePacketHeader(
        flags: flags,
        sequence: sequence,
        payloadLength: UInt16(payload.count)
    )
    connection.send(content: header.serialize() + payload, completion: .idempotent)
}

@MainActor
private func assertTrustOutcomeFailsClosed(
    _ outcome: LoomTrustEvaluation
) async throws {
    let pair = try await makeLoopbackPair()
    defer {
        Task {
            await pair.stop()
        }
    }

    let provider = FixedTrustProvider(outcome: outcome)
    let clientResult = Task {
        try await pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
    }
    let serverResult = Task {
        try await pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: provider
        )
    }

    await assertAuthenticationFailed(clientResult)
    await assertAuthenticationFailed(serverResult)
    #expect(provider.evaluatedPeerCount == 1)
    #expect(await pair.client.state == .failed("denied"))
    #expect(await pair.server.state == .failed("denied"))
}

private func assertAuthenticationFailed(
    _ task: Task<LoomAuthenticatedSessionContext, Error>
) async {
    do {
        _ = try await task.value
        Issue.record("Expected authenticated session start to fail closed.")
    } catch LoomError.authenticationFailed {
        return
    } catch {
        Issue.record("Expected LoomError.authenticationFailed, got \(error.localizedDescription).")
    }
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

private func collectPayloads(
    from stream: LoomMultiplexedStream,
    count: Int,
    timeoutSeconds: TimeInterval
) async -> [Data]? {
    await withTaskGroup(of: [Data]?.self) { group in
        group.addTask {
            await collectPayloads(from: stream, count: count)
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(Int(timeoutSeconds * 1000)))
            return nil
        }

        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private func waitUntilSessionFinished(_ session: LoomAuthenticatedSession) async {
    let states = await session.makeStateObserver()
    for await state in states {
        switch state {
        case .cancelled, .failed:
            return
        case .idle, .handshaking, .ready:
            break
        }
    }
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

    func take(timeoutSeconds: TimeInterval) async -> Value? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            if let value {
                self.value = nil
                return value
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
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

private actor BatchedPayloadCollector {
    private let targetCount: Int
    private var payloads: [Data] = []

    init(targetCount: Int) {
        self.targetCount = targetCount
    }

    func append(_ batch: [Data]) {
        payloads.append(contentsOf: batch)
    }

    func payloads(timeoutSeconds: TimeInterval) async -> [Data]? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while payloads.count < targetCount, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard payloads.count >= targetCount else { return nil }
        return Array(payloads.prefix(targetCount))
    }

    func payloadSnapshot() -> [Data] {
        payloads
    }
}

private actor BlockingBatchHandler {
    private var batches: [[Data]] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    var batchCount: Int {
        batches.count
    }

    func handle(_ batch: [Data]) async {
        batches.append(batch)
        let waiters = startedWaiters
        startedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard batches.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class SynchronousCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class SynchronousBatchedPayloadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let targetCount: Int
    private var payloads: [Data] = []
    private var maxBatchSize = 0

    init(targetCount: Int) {
        self.targetCount = targetCount
    }

    func append(_ batch: [Data]) {
        lock.lock()
        payloads.append(contentsOf: batch)
        maxBatchSize = max(maxBatchSize, batch.count)
        lock.unlock()
    }

    func payloads(timeoutSeconds: TimeInterval) async -> [Data]? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while payloadCountSnapshot() < targetCount, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = payloadSnapshot()
        guard snapshot.count >= targetCount else { return nil }
        return Array(snapshot.prefix(targetCount))
    }

    func maxBatchSizeSnapshot() -> Int {
        lock.lock()
        let value = maxBatchSize
        lock.unlock()
        return value
    }

    private func payloadCountSnapshot() -> Int {
        lock.lock()
        let count = payloads.count
        lock.unlock()
        return count
    }

    func payloadSnapshot() -> [Data] {
        lock.lock()
        let snapshot = payloads
        lock.unlock()
        return snapshot
    }
}

@MainActor
private final class FixedTrustProvider: LoomTrustProvider {
    let outcome: LoomTrustEvaluation
    private(set) var evaluatedPeerCount = 0

    init(outcome: LoomTrustEvaluation) {
        self.outcome = outcome
    }

    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        evaluatedPeerCount += 1
        return outcome.decision
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        evaluatedPeerCount += 1
        return outcome
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {}

    func revokeTrust(for deviceID: UUID) async throws {}
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

@MainActor
private final class DelayedTrustProvider: LoomTrustProvider {
    let delay: Duration
    private(set) var evaluatedPeerCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        (await evaluateTrustOutcome(for: peer)).decision
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        evaluatedPeerCount += 1
        try? await Task.sleep(for: delay)
        return LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {}

    func revokeTrust(for deviceID: UUID) async throws {}
}

@MainActor
private final class CancellationAwareTrustProvider: LoomTrustProvider {
    private(set) var didObserveCancellation = false

    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        (await evaluateTrustOutcome(for: peer)).decision
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            didObserveCancellation = true
        } catch {}
        return LoomTrustEvaluation(decision: .denied, shouldShowAutoTrustNotice: false)
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {}

    func revokeTrust(for deviceID: UUID) async throws {}
}

@MainActor
private final class CancellationInsensitiveTrustProvider: LoomTrustProvider {
    private var isReleased = false
    private var didStart = false
    private var trustContinuations: [CheckedContinuation<Void, Never>] = []
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        (await evaluateTrustOutcome(for: peer)).decision
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        didStart = true
        let startContinuations = startContinuations
        self.startContinuations.removeAll(keepingCapacity: false)
        startContinuations.forEach { $0.resume() }
        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    trustContinuations.append(continuation)
                }
            }
        }
        return LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            if didStart {
                continuation.resume()
            } else {
                startContinuations.append(continuation)
            }
        }
    }

    func release() {
        isReleased = true
        let trustContinuations = trustContinuations
        self.trustContinuations.removeAll(keepingCapacity: false)
        trustContinuations.forEach { $0.resume() }
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {}

    func revokeTrust(for deviceID: UUID) async throws {}
}
