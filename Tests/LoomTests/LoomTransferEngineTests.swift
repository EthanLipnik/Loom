//
//  LoomTransferEngineTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
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
            identityManager: serverIdentityManager
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
        rawSession: LoomSession(connection: clientConnection),
        role: .initiator,
        transportKind: .tcp
    )
    let server = LoomAuthenticatedSession(
        rawSession: LoomSession(connection: serverConnection),
        role: .receiver,
        transportKind: .tcp
    )

    return TransferPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
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

private func terminalProgress(
    from stream: AsyncStream<LoomTransferProgress>
) async -> LoomTransferProgress? {
    var last: LoomTransferProgress?
    for await progress in stream {
        last = progress
    }
    return last
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
