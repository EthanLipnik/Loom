//
//  LoomTransferEngineTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import Loom
import CryptoKit
import Foundation
import Network
import Testing

@Suite("Loom Transfer Engine", .serialized)
struct LoomTransferEngineTests {
    @MainActor
    @Test("Accepted transfers stream object bytes to completion")
    func acceptedTransferCompletes() async throws {
        let pair = try await makeTransferPair()
        defer {
            Task {
                await pair.stop()
            }
        }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(session: pair.server)
        let sourceData = Data("hello loom transfer".utf8)
        let source = MemoryTransferSource(data: sourceData)
        let offer = LoomTransferOffer(
            logicalName: "greeting.txt",
            byteLength: UInt64(sourceData.count),
            contentType: "text/plain",
            sha256Hex: sourceData.sha256Hex
        )

        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers {
                return incoming
            }
            return nil
        }

        let outgoing = try await sender.offerTransfer(offer, source: source)
        let incoming = try #require(await incomingTask.value)
        let sink = MemoryTransferSink()
        try await incoming.accept(using: sink)

        let outgoingTerminal = await terminalProgress(from: outgoing.progressEvents)
        let incomingTerminal = await terminalProgress(from: incoming.progressEvents)

        #expect(outgoingTerminal?.state == .completed)
        #expect(incomingTerminal?.state == .completed)
        #expect(await sink.data == sourceData)
    }

    @MainActor
    @Test("Declined transfers surface a declined terminal state to the sender")
    func declinedTransferPropagates() async throws {
        let pair = try await makeTransferPair()
        defer {
            Task {
                await pair.stop()
            }
        }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(session: pair.server)
        let sourceData = Data(repeating: 0x11, count: 32 * 1024)
        let source = MemoryTransferSource(data: sourceData)
        let offer = LoomTransferOffer(
            logicalName: "decline.bin",
            byteLength: UInt64(sourceData.count)
        )

        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers {
                return incoming
            }
            return nil
        }

        let outgoing = try await sender.offerTransfer(offer, source: source)
        let incoming = try #require(await incomingTask.value)
        try await incoming.decline()

        let outgoingTerminal = await terminalProgress(from: outgoing.progressEvents)
        #expect(outgoingTerminal?.state == .declined)
    }

    @MainActor
    @Test("Accepted transfers can resume from a contiguous prefix")
    func transferResumesFromPrefix() async throws {
        try await LoomGlobalSinkTestLock.shared.runOnMainActor(reset: {
            await LoomInstrumentation.resetForTesting()
            await LoomDiagnostics.resetForTesting()
        }) {
            let sinkRecorder = TransferEventSink()
            _ = await LoomInstrumentation.addSink(sinkRecorder)
            _ = await LoomDiagnostics.addSink(sinkRecorder)
            let pair = try await makeTransferPair()
            defer {
                Task {
                    await pair.stop()
                }
            }
            try await pair.startSessions()

            let sender = LoomTransferEngine(session: pair.client)
            let receiver = LoomTransferEngine(session: pair.server)
            let sourceData = Data("0123456789abcdefghij".utf8)
            let resumeOffset = UInt64(10)
            let source = MemoryTransferSource(data: sourceData)
            let offer = LoomTransferOffer(
                logicalName: "resume.txt",
                byteLength: UInt64(sourceData.count)
            )

            let incomingTask = Task<LoomIncomingTransfer?, Never> {
                for await incoming in receiver.incomingTransfers {
                    return incoming
                }
                return nil
            }

            let outgoing = try await sender.offerTransfer(offer, source: source)
            let incoming = try #require(await incomingTask.value)
            let sink = MemoryTransferSink(initialData: Data(sourceData.prefix(Int(resumeOffset))))
            try await incoming.accept(using: sink, resumeOffset: resumeOffset)

            let outgoingTerminal = await terminalProgress(from: outgoing.progressEvents)
            let incomingTerminal = await terminalProgress(from: incoming.progressEvents)

            #expect(outgoingTerminal?.state == .completed)
            #expect(incomingTerminal?.state == .completed)
            #expect(await sink.data == sourceData)
            #expect(await waitUntil {
                let stepNames = await sinkRecorder.stepNames()
                let logMessages = await sinkRecorder.logMessages()
                return stepNames.contains("loom.transfer.accept.resumed") &&
                    stepNames.contains("loom.transfer.outgoing_start.resumed") &&
                    stepNames.contains("loom.transfer.complete.outgoing.resumed") &&
                    stepNames.contains("loom.transfer.complete.incoming.resumed") &&
                    logMessages.contains { $0.contains("resumeOffset=10") && $0.contains("bytesPerSecond=") }
            })
        }
    }

    @MainActor
    @Test("Integrity mismatches fail the incoming transfer")
    func integrityMismatchFailsIncomingTransfer() async throws {
        try await LoomGlobalSinkTestLock.shared.runOnMainActor(reset: {
            await LoomInstrumentation.resetForTesting()
            await LoomDiagnostics.resetForTesting()
        }) {
            let sinkRecorder = TransferEventSink()
            _ = await LoomInstrumentation.addSink(sinkRecorder)
            _ = await LoomDiagnostics.addSink(sinkRecorder)
            let pair = try await makeTransferPair()
            defer {
                Task {
                    await pair.stop()
                }
            }
            try await pair.startSessions()

            let sender = LoomTransferEngine(session: pair.client)
            let receiver = LoomTransferEngine(session: pair.server)
            let sourceData = Data("integrity".utf8)
            let source = MemoryTransferSource(data: sourceData)
            let offer = LoomTransferOffer(
                logicalName: "integrity.txt",
                byteLength: UInt64(sourceData.count),
                sha256Hex: String(repeating: "0", count: 64)
            )

            let incomingTask = Task<LoomIncomingTransfer?, Never> {
                for await incoming in receiver.incomingTransfers {
                    return incoming
                }
                return nil
            }

            _ = try await sender.offerTransfer(offer, source: source)
            let incoming = try #require(await incomingTask.value)
            let sink = MemoryTransferSink()
            try await incoming.accept(using: sink)

            let incomingTerminal = await terminalProgress(from: incoming.progressEvents)
            #expect(incomingTerminal?.state == .failed)
            #expect(await waitUntil {
                let steps = await sinkRecorder.stepNames()
                let errors = await sinkRecorder.errorMessages()
                return steps.contains("loom.transfer.integrity_mismatch") &&
                    errors.contains { $0.contains("integrity mismatch") }
            })
        }
    }

    @MainActor
    @Test("Cancelling an outgoing transfer notifies the receiver")
    func cancellingOutgoingTransferNotifiesReceiver() async throws {
        let pair = try await makeTransferPair()
        defer {
            Task {
                await pair.stop()
            }
        }
        try await pair.startSessions()

        let sender = LoomTransferEngine(
            session: pair.client,
            configuration: LoomTransferConfiguration(
                chunkSize: 16 * 1024,
                perTransferWindowBytes: 16 * 1024,
                globalWindowBytes: 16 * 1024,
                smallObjectThresholdBytes: 32 * 1024
            )
        )
        let receiver = LoomTransferEngine(session: pair.server)
        let sourceData = Data(repeating: 0xAA, count: 128 * 1024)
        let source = DelayedTransferSource(
            data: sourceData,
            delay: .milliseconds(100)
        )
        let offer = LoomTransferOffer(
            logicalName: "cancel.bin",
            byteLength: UInt64(sourceData.count)
        )

        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers {
                return incoming
            }
            return nil
        }

        let outgoing = try await sender.offerTransfer(offer, source: source)
        let incoming = try #require(await incomingTask.value)
        let sink = MemoryTransferSink()
        try await incoming.accept(using: sink)

        try? await Task.sleep(for: .milliseconds(30))
        await outgoing.cancel()

        let outgoingTerminal = await terminalProgress(from: outgoing.progressEvents)
        let incomingTerminal = await terminalProgress(from: incoming.progressEvents)

        #expect(outgoingTerminal?.state == .cancelled)
        #expect(incomingTerminal?.state == .cancelled)
    }

    @MainActor
    @Test("Invalid resume offsets are rejected without crashing the sender")
    func invalidResumeOffsetIsRejected() async throws {
        let pair = try await makeTransferPair()
        defer {
            Task {
                await pair.stop()
            }
        }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(session: pair.server)
        let sourceData = Data("resume bounds".utf8)
        let source = MemoryTransferSource(data: sourceData)
        let offer = LoomTransferOffer(
            logicalName: "bounds.txt",
            byteLength: UInt64(sourceData.count)
        )

        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers {
                return incoming
            }
            return nil
        }

        let outgoing = try await sender.offerTransfer(offer, source: source)
        let incoming = try #require(await incomingTask.value)
        let sink = MemoryTransferSink(initialData: sourceData)
        let invalidOffset = UInt64(sourceData.count + 1)
        await #expect(throws: LoomTransferError.self) {
            try await incoming.accept(using: sink, resumeOffset: invalidOffset)
        }

        let outgoingTerminal = await terminalProgress(from: outgoing.progressEvents)
        #expect(outgoingTerminal?.state == .cancelled)
    }

    @Test("Incoming payload bounds are enforced before sink writes")
    func incomingPayloadBoundsAreEnforcedBeforeWrites() throws {
        #expect(try LoomTransferEngine.validatedIncomingOffset(
            offset: 8,
            payloadCount: 2,
            offerByteLength: 10
        ) == 10)
        #expect(throws: LoomTransferError.self) {
            try LoomTransferEngine.validatedIncomingOffset(
                offset: 8,
                payloadCount: 3,
                offerByteLength: 10
            )
        }
        #expect(throws: LoomTransferError.self) {
            try LoomTransferEngine.validatedIncomingOffset(
                offset: 8,
                payloadCount: 0,
                offerByteLength: 10
            )
        }
    }

    @MainActor
    @Test("Unmatched data streams expire instead of permanently consuming admission")
    func unmatchedDataStreamsExpire() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let receiver = LoomTransferEngine(
            session: pair.server,
            configuration: LoomTransferConfiguration(
                maxPendingDataStreams: 1,
                pendingDataStreamTimeout: .milliseconds(50)
            )
        )
        await Task.yield()
        let transferID = UUID()
        let unmatchedStream = try await pair.client.openStream(
            label: "loom.transfer.data.\(transferID.uuidString.lowercased())"
        )

        #expect(await waitUntil { await receiver.pendingDataStreamCount == 1 })
        #expect(await waitUntil { await receiver.pendingDataStreamCount == 0 })
        try? await unmatchedStream.close()
    }

    @MainActor
    @Test("Transfer sources cannot send beyond their granted or advertised range")
    func oversizedSourceChunkFailsBeforeSending() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let sender = LoomTransferEngine(
            session: pair.client,
            configuration: LoomTransferConfiguration(
                chunkSize: 16 * 1024,
                perTransferWindowBytes: 16 * 1024,
                globalWindowBytes: 16 * 1024
            )
        )
        let receiver = LoomTransferEngine(session: pair.server)
        let source = OversizedTransferSource(advertisedByteLength: 4)
        let offer = LoomTransferOffer(logicalName: "oversized.bin", byteLength: 4)
        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers { return incoming }
            return nil
        }

        let outgoing = try await sender.offerTransfer(offer, source: source)
        let incoming = try #require(await incomingTask.value)
        let sink = MemoryTransferSink()
        try await incoming.accept(using: sink)
        let outgoingTerminal = await terminalProgress(from: outgoing.progressEvents)

        #expect(outgoingTerminal?.state == .failed)
        #expect(await sink.data.isEmpty)
    }

    @MainActor
    @Test("Incoming offer state is capped and excess offers are declined")
    func incomingOfferStateIsCapped() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(
            session: pair.server,
            configuration: LoomTransferConfiguration(maxActiveTransfersPerDirection: 1)
        )
        let firstData = Data([1])
        let firstIncomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers { return incoming }
            return nil
        }
        let first = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "first.bin", byteLength: 1),
            source: MemoryTransferSource(data: firstData)
        )
        let firstIncoming = try #require(await firstIncomingTask.value)

        let second = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "second.bin", byteLength: 1),
            source: MemoryTransferSource(data: firstData)
        )
        let secondTerminal = await terminalProgress(from: second.progressEvents)

        #expect(secondTerminal?.state == .declined)
        try await firstIncoming.decline()
        #expect(await terminalProgress(from: first.progressEvents)?.state == .declined)
    }

    @MainActor
    @Test("Offer fields and source length are validated before state is retained")
    func offerFieldsAreBounded() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let engine = LoomTransferEngine(
            session: pair.client,
            configuration: LoomTransferConfiguration(
                maxOfferByteLength: 8,
                maxOfferLogicalNameBytes: 4,
                maxOfferMetadataEntries: 1,
                maxOfferMetadataBytes: 4
            )
        )
        let source = MemoryTransferSource(data: Data(repeating: 0, count: 9))

        await #expect(throws: LoomTransferError.self) {
            try await engine.offerTransfer(
                LoomTransferOffer(logicalName: "toolong", byteLength: 9),
                source: source
            )
        }
        await #expect(throws: LoomTransferError.self) {
            try await engine.offerTransfer(
                LoomTransferOffer(logicalName: "ok", byteLength: 8),
                source: source
            )
        }
    }

    @MainActor
    @Test("Transfer progress coalesces one-byte fragmentation")
    func transferProgressCoalescesOneByteFragments() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(session: pair.server)
        let sourceData = Data(repeating: 0x5A, count: 100)
        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers { return incoming }
            return nil
        }
        let outgoing = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "fragments.bin", byteLength: UInt64(sourceData.count)),
            source: OneByteTransferSource(data: sourceData)
        )
        let incoming = try #require(await incomingTask.value)
        try await incoming.accept(using: MemoryTransferSink())

        #expect(await waitUntil {
            let outgoingCount = await sender.outgoingTransferCount
            let incomingCount = await receiver.incomingTransferCount
            return outgoingCount == 0 && incomingCount == 0
        })
        let outgoingProgress = await allProgress(from: outgoing.progressEvents)
        let incomingProgress = await allProgress(from: incoming.progressEvents)
        #expect(outgoingProgress == [LoomTransferProgress(
            transferID: outgoing.offer.id,
            logicalName: outgoing.offer.logicalName,
            bytesTransferred: outgoing.offer.byteLength,
            totalBytes: outgoing.offer.byteLength,
            state: .completed
        )])
        #expect(incomingProgress.last?.state == .completed)
        #expect(incomingProgress.count == 1)
    }

    @MainActor
    @Test("Unanswered incoming offers expire and are declined")
    func unansweredIncomingOfferExpires() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let sender = LoomTransferEngine(
            session: pair.client,
            configuration: LoomTransferConfiguration(offerDecisionTimeout: .seconds(1))
        )
        let receiver = LoomTransferEngine(
            session: pair.server,
            configuration: LoomTransferConfiguration(offerDecisionTimeout: .milliseconds(50))
        )
        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers { return incoming }
            return nil
        }
        let outgoing = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "undecided.bin", byteLength: 1),
            source: MemoryTransferSource(data: Data([1]))
        )
        let incoming = try #require(await incomingTask.value)

        #expect(await terminalProgress(from: incoming.progressEvents)?.state == .declined)
        #expect(await terminalProgress(from: outgoing.progressEvents)?.state == .declined)
        #expect(await receiver.incomingTransferCount == 0)
        #expect(await sender.outgoingTransferCount == 0)
    }

    @MainActor
    @Test("Accepted transfers time out and close their sink")
    func acceptedTransferTimeoutClosesSink() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let configuration = LoomTransferConfiguration(
            offerDecisionTimeout: .seconds(1),
            activeTransferTimeout: .milliseconds(75)
        )
        let sender = LoomTransferEngine(session: pair.client, configuration: configuration)
        let receiver = LoomTransferEngine(session: pair.server, configuration: configuration)
        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers { return incoming }
            return nil
        }
        let outgoing = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "stalled.bin", byteLength: 1),
            source: HangingTransferSource()
        )
        let incoming = try #require(await incomingTask.value)
        let sink = CloseRecordingTransferSink()
        try await incoming.accept(using: sink)

        #expect(await terminalProgress(from: incoming.progressEvents)?.state == .failed)
        let outgoingTerminal = await terminalProgress(from: outgoing.progressEvents)
        #expect(outgoingTerminal?.state == .failed || outgoingTerminal?.state == .cancelled)
        #expect(await sink.didClose)
        #expect(await receiver.incomingTransferCount == 0)
        #expect(await sender.outgoingTransferCount == 0)
    }

    @MainActor
    @Test("Duplicate inbound control streams do not replace the active stream")
    func duplicateInboundControlStreamIsRejected() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(session: pair.server)
        let incomingTask = Task<[LoomIncomingTransfer], Never> {
            var offers: [LoomIncomingTransfer] = []
            for await incoming in receiver.incomingTransfers {
                offers.append(incoming)
                if offers.count == 2 { return offers }
            }
            return offers
        }
        let first = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "first-control.bin", byteLength: 1),
            source: MemoryTransferSource(data: Data([1]))
        )
        #expect(await waitUntil { await receiver.incomingTransferCount == 1 })

        let duplicate = try await pair.client.openStream(label: "loom.transfer.control.v1")
        try? await Task.sleep(for: .milliseconds(20))
        let second = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "second-control.bin", byteLength: 1),
            source: MemoryTransferSource(data: Data([2]))
        )
        let incomingOffers = await incomingTask.value
        #expect(incomingOffers.count == 2)
        for incoming in incomingOffers {
            try await incoming.decline()
        }
        #expect(await terminalProgress(from: first.progressEvents)?.state == .declined)
        #expect(await terminalProgress(from: second.progressEvents)?.state == .declined)
        try? await duplicate.close()
    }

    @MainActor
    @Test("Duplicate accept messages cannot restart an active outgoing transfer")
    func duplicateAcceptDoesNotRestartOutgoingTransfer() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(session: pair.server)
        let incomingTask = Task<LoomIncomingTransfer?, Never> {
            for await incoming in receiver.incomingTransfers { return incoming }
            return nil
        }
        let outgoing = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "duplicate-accept.bin", byteLength: 1),
            source: HangingTransferSource()
        )
        _ = try #require(await incomingTask.value)

        try await sender.startOutgoingTransferForTesting(id: outgoing.offer.id, resumeOffset: 0)
        let activeStreamCount = await pair.client.activeStreamCountForTesting
        await #expect(throws: LoomTransferError.self) {
            try await sender.startOutgoingTransferForTesting(id: outgoing.offer.id, resumeOffset: 0)
        }

        #expect(await pair.client.activeStreamCountForTesting == activeStreamCount)
        #expect(await sender.outgoingTransferCount == 1)
        await outgoing.cancel()
    }

    @MainActor
    @Test("Transfer control payloads are bounded before decoding or sending")
    func transferControlPayloadsAreBounded() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let engine = LoomTransferEngine(
            session: pair.client,
            configuration: LoomTransferConfiguration(maxControlMessageBytes: 16)
        )
        try await engine.validateControlPayloadSizeForTesting(Data(repeating: 0, count: 16))
        await #expect(throws: LoomTransferError.self) {
            try await engine.validateControlPayloadSizeForTesting(Data(repeating: 0, count: 17))
        }
        await #expect(throws: LoomTransferError.self) {
            try await engine.offerTransfer(
                LoomTransferOffer(logicalName: "bounded.bin", byteLength: 1),
                source: MemoryTransferSource(data: Data([1]))
            )
        }
        #expect(await engine.outgoingTransferCount == 0)
    }

    @MainActor
    @Test("Terminated incoming offer streams clean up and decline new offers")
    func terminatedIncomingOfferStreamDeclinesOffer() async throws {
        let pair = try await makeTransferPair()
        defer { Task { await pair.stop() } }
        try await pair.startSessions()

        let sender = LoomTransferEngine(session: pair.client)
        let receiver = LoomTransferEngine(session: pair.server)
        let consumer = Task {
            for await _ in receiver.incomingTransfers {}
        }
        await Task.yield()
        consumer.cancel()
        await consumer.value

        let outgoing = try await sender.offerTransfer(
            LoomTransferOffer(logicalName: "terminated-offers.bin", byteLength: 1),
            source: MemoryTransferSource(data: Data([1]))
        )
        #expect(await terminalProgress(from: outgoing.progressEvents)?.state == .declined)
        #expect(await receiver.incomingTransferCount == 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private struct TransferPair {
    let listener: NWListener
    let clientIdentityManager: LoomIdentityManager
    let serverIdentityManager: LoomIdentityManager
    let serverTrustProvider: TransferAlwaysTrustProvider
    let clientHello: LoomSessionHelloRequest
    let serverHello: LoomSessionHelloRequest
    let client: LoomAuthenticatedSession
    let server: LoomAuthenticatedSession

    func stop() async {
        listener.cancel()
        await client.cancel()
        await server.cancel()
    }

    func startSessions() async throws {
        async let clientContext = client.start(
            localHello: clientHello,
            identityManager: clientIdentityManager
        )
        async let serverContext = server.start(
            localHello: serverHello,
            identityManager: serverIdentityManager,
            trustProvider: serverTrustProvider
        )
        _ = try await (clientContext, serverContext)
    }
}

@MainActor
private func makeTransferPair() async throws -> TransferPair {
    let clientIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.transfer-client.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.transfer-server.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )

    let listener = try NWListener(using: .tcp, on: .any)
    let acceptedConnection = TransferAsyncBox<NWConnection>()
    let readyPort = TransferAsyncBox<UInt16>()

    listener.newConnectionHandler = { connection in
        Task { await acceptedConnection.set(connection) }
    }
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue {
            Task { await readyPort.set(port) }
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

    return TransferPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        serverTrustProvider: TransferAlwaysTrustProvider(),
        clientHello: LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Client",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(deviceType: .mac)
        ),
        serverHello: LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Server",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(deviceType: .mac)
        ),
        client: client,
        server: server
    )
}

@MainActor
private final class TransferAlwaysTrustProvider: LoomTrustProvider {
    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        .trusted
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {}

    func revokeTrust(for deviceID: UUID) async throws {}
}

private func terminalProgress(
    from stream: AsyncStream<LoomTransferProgress>
) async -> LoomTransferProgress? {
    var last: LoomTransferProgress?
    for await progress in stream {
        last = progress
    }
    return last
}

private func allProgress(
    from stream: AsyncStream<LoomTransferProgress>
) async -> [LoomTransferProgress] {
    var events: [LoomTransferProgress] = []
    for await progress in stream {
        events.append(progress)
    }
    return events
}

private struct MemoryTransferSource: LoomTransferSource {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    var byteLength: UInt64 {
        UInt64(data.count)
    }

    func read(offset: UInt64, maxLength: Int) async throws -> Data {
        guard offset < UInt64(data.count) else {
            return Data()
        }
        let lower = Int(offset)
        let upper = min(data.count, lower + maxLength)
        return Data(data[lower..<upper])
    }
}

private struct DelayedTransferSource: LoomTransferSource {
    let data: Data
    let delay: Duration

    var byteLength: UInt64 {
        UInt64(data.count)
    }

    func read(offset: UInt64, maxLength: Int) async throws -> Data {
        try await Task.sleep(for: delay)
        guard offset < UInt64(data.count) else {
            return Data()
        }
        let lower = Int(offset)
        let upper = min(data.count, lower + maxLength)
        return Data(data[lower..<upper])
    }
}

private struct OneByteTransferSource: LoomTransferSource {
    let data: Data

    var byteLength: UInt64 {
        UInt64(data.count)
    }

    func read(offset: UInt64, maxLength _: Int) async throws -> Data {
        guard offset < UInt64(data.count) else { return Data() }
        return Data([data[Int(offset)]])
    }
}

private struct HangingTransferSource: LoomTransferSource {
    let byteLength: UInt64 = 1

    func read(offset _: UInt64, maxLength _: Int) async throws -> Data {
        try await Task.sleep(for: .seconds(30))
        return Data([1])
    }
}

private struct OversizedTransferSource: LoomTransferSource {
    let advertisedByteLength: UInt64

    var byteLength: UInt64 { advertisedByteLength }

    func read(offset _: UInt64, maxLength: Int) async throws -> Data {
        Data(repeating: 0xA5, count: maxLength + 1)
    }
}

private actor MemoryTransferSink: LoomTransferSink {
    private(set) var data: Data

    init(initialData: Data = Data()) {
        data = initialData
    }

    func truncate(to byteCount: UInt64) async throws {
        let count = Int(byteCount)
        if data.count > count {
            data.removeSubrange(count..<data.count)
        } else if data.count < count {
            data.append(Data(repeating: 0, count: count - data.count))
        }
    }

    func write(_ chunk: Data, at offset: UInt64) async throws {
        let lower = Int(offset)
        if data.count < lower {
            data.append(Data(repeating: 0, count: lower - data.count))
        }
        let upper = lower + chunk.count
        if data.count < upper {
            data.append(Data(repeating: 0, count: upper - data.count))
        }
        data.replaceSubrange(lower..<upper, with: chunk)
    }

    func finalize(offer _: LoomTransferOffer, bytesWritten _: UInt64) async throws {}
}

private actor CloseRecordingTransferSink: LoomTransferSink {
    private(set) var didClose = false

    func truncate(to _: UInt64) async throws {}

    func write(_: Data, at _: UInt64) async throws {}

    func finalize(offer _: LoomTransferOffer, bytesWritten _: UInt64) async throws {}

    func close() async throws {
        didClose = true
    }
}

private actor TransferAsyncBox<Value: Sendable> {
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

private actor TransferEventSink: LoomInstrumentationSink, LoomDiagnosticsSink {
    private var steps: [String] = []
    private var logs: [String] = []
    private var errors: [String] = []

    func record(event: LoomInstrumentationEvent) async {
        steps.append(event.name)
    }

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event.message)
    }

    func record(error event: LoomDiagnosticsErrorEvent) async {
        errors.append(event.message)
    }

    func stepNames() -> [String] {
        steps
    }

    func logMessages() -> [String] {
        logs
    }

    func errorMessages() -> [String] {
        errors
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
