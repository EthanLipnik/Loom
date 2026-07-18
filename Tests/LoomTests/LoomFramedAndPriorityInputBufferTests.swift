//
//  LoomFramedAndPriorityInputBufferTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

@testable import Loom
import Dispatch
import Foundation
import LoomNetworking
import Network
import Testing

@Suite("Framed and Priority Input Receive Bounds", .serialized)
struct LoomFramedAndPriorityInputBufferTests {
    @Test("Framed receive storage releases aggregate reservations after consumption")
    func framedReceiveStorageReleasesReservationsAfterConsumption() throws {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 32,
            maximumPayloadCount: 4,
            maximumBatchCount: 4
        )
        let buffer = LoomFramedReceiveBuffer(retainedCapacityBudget: budget)
        let payload = Data([1, 2, 3, 4])

        try buffer.append(frameHeader(payloadLength: payload.count))
        try buffer.append(payload)

        #expect(budget.retainedBytesForTesting == 8)
        #expect(try buffer.consumeCompleteFrame(requiredBytes: 8) == payload)
        #expect(buffer.retainedStorageBytesForTesting == 0)
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Framed receive storage fails closed at the aggregate byte budget")
    func framedReceiveStorageEnforcesAggregateBudget() throws {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 7,
            maximumPayloadCount: 4,
            maximumBatchCount: 4
        )
        let buffer = LoomFramedReceiveBuffer(retainedCapacityBudget: budget)

        try buffer.append(frameHeader(payloadLength: 4))
        #expect(throws: LoomError.self) {
            try buffer.append(Data(repeating: 0xAA, count: 4))
        }
        #expect(budget.retainedBytesForTesting == 4)

        buffer.discard()
        #expect(buffer.retainedStorageBytesForTesting == 0)
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Framed receive storage drops a large frame allocation after consumption")
    func framedReceiveStorageResetsAfterLargeFrame() throws {
        let payload = Data(repeating: 0x5A, count: 8 * 1024 * 1024)
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: payload.count + 4,
            maximumPayloadCount: 2,
            maximumBatchCount: 2
        )
        let buffer = LoomFramedReceiveBuffer(retainedCapacityBudget: budget)

        try buffer.append(frameHeader(payloadLength: payload.count))
        try buffer.append(payload)
        #expect(try buffer.consumeCompleteFrame(requiredBytes: payload.count + 4) == payload)

        #expect(buffer.retainedStorageBytesForTesting == 0)
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Framed receive storage retains surplus with exact budget accounting")
    func framedReceiveStorageRetainsSurplus() throws {
        let firstPayload = Data([1, 2])
        let secondPayload = Data([3, 4, 5])
        let firstFrame = framedTCPBytes(firstPayload)
        let secondFrame = framedTCPBytes(secondPayload)
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: firstFrame.count + secondFrame.count,
            maximumPayloadCount: 2,
            maximumBatchCount: 2
        )
        let buffer = LoomFramedReceiveBuffer(retainedCapacityBudget: budget)

        try buffer.append(firstFrame + secondFrame)
        #expect(try buffer.consumeCompleteFrame(requiredBytes: firstFrame.count) == firstPayload)
        #expect(buffer.retainedStorageBytesForTesting == secondFrame.count)
        #expect(budget.retainedBytesForTesting == secondFrame.count)

        #expect(try buffer.consumeCompleteFrame(requiredBytes: secondFrame.count) == secondPayload)
        #expect(buffer.retainedStorageBytesForTesting == 0)
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Framed receive storage counts coalesced logical frames against payload budget")
    func framedReceiveStorageCountsCoalescedFrames() throws {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 64,
            maximumPayloadCount: 1,
            maximumBatchCount: 1
        )
        let buffer = LoomFramedReceiveBuffer(retainedCapacityBudget: budget)

        #expect(throws: LoomError.self) {
            try buffer.append(framedTCPBytes(Data([1])) + framedTCPBytes(Data([2])))
        }
        #expect(buffer.retainedStorageBytesForTesting == 0)
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Framed TCP drains coalesced frames in one bounded batch")
    func framedTCPDrainsCoalescedFrames() async throws {
        let payloads = [Data([1]), Data([2, 2]), Data([3, 3, 3])]
        let connection = LoomFramedChunkConnection(chunks: [
            payloads.reduce(into: Data()) { bytes, payload in
                bytes.append(framedTCPBytes(payload))
            }
        ])
        let framedConnection = LoomFramedConnection(connection: connection)

        let batch = try await framedConnection.readFrames(maxBytes: 16, maximumFrames: 3)

        #expect(batch == payloads)
        #expect(await connection.receiveCallCount == 1)
    }

    @Test("Framed TCP reassembles split frames and preserves order")
    func framedTCPReassemblesSplitFrames() async throws {
        let firstPayload = Data([0x11, 0x12, 0x13])
        let secondPayload = Data([0x21, 0x22])
        let bytes = framedTCPBytes(firstPayload) + framedTCPBytes(secondPayload)
        let connection = LoomFramedChunkConnection(chunks: [
            Data(bytes.prefix(2)),
            Data(bytes.dropFirst(2).prefix(4)),
            Data(bytes.dropFirst(6).prefix(3)),
            Data(bytes.dropFirst(9))
        ])
        let framedConnection = LoomFramedConnection(connection: connection)

        #expect(try await framedConnection.readFrame(maxBytes: 16) == firstPayload)
        #expect(try await framedConnection.readFrame(maxBytes: 16) == secondPayload)
        #expect(await connection.receiveCallCount == 4)
    }

    @Test("Framed TCP retains coalesced surplus across bounded batch calls")
    func framedTCPRetainsSurplusAcrossBatchCalls() async throws {
        let payloads = [Data([1]), Data([2]), Data([3])]
        let coalesced = payloads.reduce(into: Data()) { bytes, payload in
            bytes.append(framedTCPBytes(payload))
        }
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: coalesced.count,
            maximumPayloadCount: payloads.count,
            maximumBatchCount: payloads.count
        )
        let connection = LoomFramedChunkConnection(chunks: [coalesced])
        let framedConnection = LoomFramedConnection(
            connection: connection,
            retainedCapacityBudget: budget
        )

        #expect(try await framedConnection.readFrames(maxBytes: 16, maximumFrames: 2) == Array(payloads.prefix(2)))
        #expect(await connection.receiveCallCount == 1)
        #expect(budget.retainedBytesForTesting == framedTCPBytes(payloads[2]).count)

        #expect(try await framedConnection.readFrames(maxBytes: 16, maximumFrames: 2) == [payloads[2]])
        #expect(await connection.receiveCallCount == 1)
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Framed TCP rejects oversized declared lengths before reading payload")
    func framedTCPRejectsOversizedDeclaredLength() async {
        let connection = LoomFramedChunkConnection(chunks: [frameHeader(payloadLength: 17)])
        let framedConnection = LoomFramedConnection(connection: connection)

        await #expect(throws: LoomError.self) {
            try await framedConnection.readFrames(maxBytes: 16, maximumFrames: 4)
        }
        #expect(await connection.receiveCallCount == 1)
        #expect(await connection.cancelCount == 1)
    }

    @Test("Framed TCP rejects malicious wire lengths and releases retained budget")
    func framedTCPRejectsMaliciousWireLength() async {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 64,
            maximumPayloadCount: 1,
            maximumBatchCount: 1
        )
        let connection = LoomFramedChunkConnection(chunks: [Data(repeating: 0xFF, count: 4)])
        let framedConnection = LoomFramedConnection(
            connection: connection,
            retainedCapacityBudget: budget
        )

        await #expect(throws: LoomError.self) {
            try await framedConnection.readFrames(
                maxBytes: LoomMessageLimits.maxFrameBytes,
                maximumFrames: 4
            )
        }
        #expect(budget.retainedBytesForTesting == 0)
        #expect(await connection.cancelCount == 1)
    }

    @Test("Framed receive deadline starts after the first byte, not while idle")
    func framedReceiveDeadlineDoesNotExpireWhileIdle() async throws {
        let pair = try await makeFramedTCPPair(incompleteFrameTimeout: .milliseconds(100))
        defer { pair.cancel() }

        let readTask = Task {
            try await pair.framedConnection.readFrame(maxBytes: 16)
        }
        try await Task.sleep(for: .milliseconds(250))
        try await sendTCPFrame(Data([0x2A]), over: pair.serverConnection)

        let payload = try await withLoomThrowingDeadline(.now + .seconds(2)) {
            try await readTask.value
        }
        #expect(payload == Data([0x2A]))
    }

    @Test("Incomplete framed receive times out and releases its reservation")
    func incompleteFramedReceiveTimesOutAndReleasesReservation() async throws {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 1024,
            maximumPayloadCount: 16,
            maximumBatchCount: 16
        )
        let pair = try await makeFramedTCPPair(
            retainedCapacityBudget: budget,
            incompleteFrameTimeout: .milliseconds(100)
        )
        defer { pair.cancel() }

        try await sendTCPBytes(Data([0]), over: pair.serverConnection)
        await #expect(throws: LoomError.self) {
            try await withLoomThrowingDeadline(.now + .seconds(2)) {
                try await pair.framedConnection.readFrame(maxBytes: 16)
            }
        }

        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Incomplete surplus keeps its original framed receive deadline")
    func incompleteSurplusKeepsOriginalDeadline() async throws {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 1024,
            maximumPayloadCount: 2,
            maximumBatchCount: 2
        )
        let pair = try await makeFramedTCPPair(
            retainedCapacityBudget: budget,
            incompleteFrameTimeout: .milliseconds(100)
        )
        defer { pair.cancel() }

        try await sendTCPBytes(
            framedTCPBytes(Data([0x2A])) + Data([0]),
            over: pair.serverConnection
        )
        #expect(try await pair.framedConnection.readFrame(maxBytes: 16) == Data([0x2A]))
        try await Task.sleep(for: .milliseconds(150))

        await #expect(throws: LoomError.self) {
            try await withLoomThrowingDeadline(.now + .seconds(2)) {
                try await pair.framedConnection.readFrame(maxBytes: 16)
            }
        }
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Priority input buffer preserves order and releases reservations on consume")
    func priorityInputBufferPreservesOrderAndReleasesReservations() async {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 8,
            maximumPayloadCount: 2,
            maximumBatchCount: 2
        )
        let buffer = LoomPriorityIncomingPayloadBuffer(
            maximumBufferedBytes: 8,
            maximumBufferedItems: 2,
            retainedCapacityBudget: budget
        )
        let stream = buffer.makeStream()

        #expect(buffer.yield(Data([1, 2])) == .accepted)
        #expect(buffer.yield(Data([3, 4])) == .accepted)
        #expect(budget.retainedBytesForTesting == 4)
        buffer.finish()

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == Data([1, 2]))
        #expect(budget.retainedBytesForTesting == 2)
        #expect(await iterator.next() == Data([3, 4]))
        #expect(budget.retainedBytesForTesting == 0)
        #expect(await iterator.next() == nil)
    }

    @Test("Priority input overflow aborts without silently dropping one payload")
    func priorityInputOverflowAbortsAndReleasesReservations() async {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 8,
            maximumPayloadCount: 2,
            maximumBatchCount: 2
        )
        let buffer = LoomPriorityIncomingPayloadBuffer(
            maximumBufferedBytes: 4,
            maximumBufferedItems: 1,
            retainedCapacityBudget: budget
        )
        let stream = buffer.makeStream()

        #expect(buffer.yield(Data([1, 2, 3, 4])) == .accepted)
        #expect(buffer.yield(Data([5])) == .overflow)
        buffer.abort()

        #expect(buffer.bufferedBytesForTesting == 0)
        #expect(budget.retainedBytesForTesting == 0)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("Lossy data buffering replaces the oldest payload and releases its reservation")
    func lossyDataBufferKeepsFreshestPayloads() async {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 4,
            maximumPayloadCount: 2,
            maximumBatchCount: 2
        )
        let buffer = LoomBoundedIncomingDataBuffer(
            maximumBufferedBytes: 4,
            maximumBufferedItems: 2,
            retainedCapacityBudget: budget
        )
        let stream = buffer.makeStream()

        #expect(buffer.yieldReplacingOldest(Data([1, 1])).result == .accepted)
        #expect(buffer.yieldReplacingOldest(Data([2, 2])).result == .accepted)
        let replacement = buffer.yieldReplacingOldest(Data([3, 3]))
        #expect(replacement.result == .accepted)
        #expect(replacement.replacedPayloadCount == 1)
        #expect(budget.retainedBytesForTesting == 4)
        buffer.finish()

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == Data([2, 2]))
        #expect(await iterator.next() == Data([3, 3]))
        #expect(await iterator.next() == nil)
        #expect(budget.retainedBytesForTesting == 0)
    }

    @Test("Bounded data buffering drains available payloads in batches")
    func boundedDataBufferDrainsAvailableBatch() async {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 16,
            maximumPayloadCount: 4,
            maximumBatchCount: 4
        )
        let buffer = LoomBoundedIncomingDataBuffer(
            maximumBufferedBytes: 16,
            maximumBufferedItems: 4,
            retainedCapacityBudget: budget
        )

        #expect(buffer.yield(Data([1])) == .accepted)
        #expect(buffer.yield(Data([2])) == .accepted)
        #expect(buffer.yield(Data([3])) == .accepted)
        #expect(await buffer.nextBatch(maximumCount: 2) == [Data([1]), Data([2])])
        #expect(budget.retainedBytesForTesting == 1)
        #expect(await buffer.nextBatch(maximumCount: 2) == [Data([3])])
        #expect(budget.retainedBytesForTesting == 0)
    }

    @MainActor
    @Test("Priority endpoint terminates its producer and releases budget on output overflow")
    func priorityEndpointTerminatesOnOutputOverflow() async throws {
        let contexts = try makePriorityInputSecurityContexts()
        let frames = try [Data([1, 2, 3]), Data([4, 5, 6])].map { payload in
            var frame = Data([LoomSessionTrafficClass.priorityInput.rawValue])
            frame.append(
                try contexts.sender.seal(
                    payload,
                    trafficClass: .priorityInput
                )
            )
            return frame
        }
        let source = LoomPriorityInputFrameSource(frames: frames)
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 16,
            maximumPayloadCount: 4,
            maximumBatchCount: 4
        )
        let endpoint = LoomPriorityInputEndpoint(
            securityContext: contexts.receiver,
            sendFrame: { _, _, onComplete in onComplete(nil) },
            receiveFrame: { maximumBytes in
                try await source.next(maximumBytes: maximumBytes)
            },
            retainedCapacityBudget: budget,
            maximumBufferedIncomingBytes: 8,
            maximumBufferedIncomingPayloads: 1
        )

        let stream = endpoint.makeIncomingPayloadStream(maxBytes: 8)
        try await withLoomThrowingDeadline(.now + .seconds(2)) {
            while await source.receivedFrameCount < 2 || budget.retainedBytesForTesting > 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        #expect(budget.retainedBytesForTesting == 0)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

private struct LoomFramedTCPPair {
    let listener: NWListener
    let serverConnection: NWConnection
    let framedConnection: LoomFramedConnection

    func cancel() {
        listener.cancel()
        serverConnection.cancel()
        Task {
            await framedConnection.closeTransport()
        }
    }
}

private enum LoomFramedTCPTestError: Error {
    case cancelled
    case missingListenerPort
    case timedOut
}

private enum LoomPriorityInputFrameSourceError: Error {
    case exhausted
    case oversizedFrame
}

private actor LoomPriorityInputFrameSource {
    private var frames: [Data]
    private(set) var receivedFrameCount = 0

    init(frames: [Data]) {
        self.frames = frames
    }

    func next(maximumBytes: Int) throws -> Data {
        guard !frames.isEmpty else {
            throw LoomPriorityInputFrameSourceError.exhausted
        }
        let frame = frames.removeFirst()
        guard frame.count <= maximumBytes else {
            throw LoomPriorityInputFrameSourceError.oversizedFrame
        }
        receivedFrameCount += 1
        return frame
    }
}

private struct LoomPriorityInputSecurityContexts {
    let sender: LoomSessionSecurityContext
    let receiver: LoomSessionSecurityContext
}

@MainActor
private func makePriorityInputSecurityContexts() throws -> LoomPriorityInputSecurityContexts {
    let initiatorIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.priority-input-sender.\(UUID().uuidString)",
        account: "initiator",
        synchronizable: false
    )
    let receiverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.priority-input-receiver.\(UUID().uuidString)",
        account: "receiver",
        synchronizable: false
    )
    let initiatorHello = try LoomSessionHelloValidator.makePreparedSignedHello(
        from: LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Priority Input Sender",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement()
        ),
        identityManager: initiatorIdentityManager
    )
    let receiverHello = try LoomSessionHelloValidator.makePreparedSignedHello(
        from: LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Priority Input Receiver",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement()
        ),
        identityManager: receiverIdentityManager
    )

    return try LoomPriorityInputSecurityContexts(
        sender: LoomSessionSecurityContext(
            role: .initiator,
            localHello: initiatorHello.hello,
            remoteHello: receiverHello.hello,
            localEphemeralPrivateKey: initiatorHello.ephemeralPrivateKey
        ),
        receiver: LoomSessionSecurityContext(
            role: .receiver,
            localHello: receiverHello.hello,
            remoteHello: initiatorHello.hello,
            localEphemeralPrivateKey: receiverHello.ephemeralPrivateKey
        )
    )
}

private func frameHeader(payloadLength: Int) -> Data {
    var length = UInt32(payloadLength).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) }
}

private func framedTCPBytes(_ payload: Data) -> Data {
    frameHeader(payloadLength: payload.count) + payload
}

private actor LoomFramedChunkConnection: LoomNetworkConnection {
    nonisolated let transportKind = LoomNetworking.LoomTransportKind.tcp
    nonisolated let remoteEndpoint = LoomNetworkEndpoint.opaque(description: "framed-chunk-test")
    var localEndpoint: LoomNetworkEndpoint? { get async { nil } }
    var currentPath: LoomNetworkPath? { get async { nil } }

    private var chunks: [Data]
    private(set) var receiveCallCount = 0
    private(set) var cancelCount = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func start() async throws {}
    func send(_ data: Data) async throws { _ = data }

    func receive(maximumBytes: Int) async throws -> Data? {
        receiveCallCount += 1
        guard !chunks.isEmpty else { return nil }
        let chunk = chunks.removeFirst()
        guard chunk.count > maximumBytes else { return chunk }
        let prefix = Data(chunk.prefix(maximumBytes))
        chunks.insert(Data(chunk.dropFirst(maximumBytes)), at: 0)
        return prefix
    }

    func makeEventStream() async -> AsyncStream<LoomNetworkConnectionEvent> {
        AsyncStream { $0.finish() }
    }

    func cancel() async {
        cancelCount += 1
    }
}

private func makeFramedTCPPair(
    retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
    incompleteFrameTimeout: Duration
) async throws -> LoomFramedTCPPair {
    let queue = DispatchQueue(label: "loom.tests.framed-connection")
    let listener = try NWListener(using: .tcp, on: .any)
    let acceptedConnection = LoomFramedTCPTestValueBox<NWConnection>()
    listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        acceptedConnection.store(connection)
    }
    try await startFramedTCPListener(listener, queue: queue)
    guard let port = listener.port else {
        listener.cancel()
        throw LoomFramedTCPTestError.missingListenerPort
    }

    let clientConnection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    let framedConnection = LoomFramedConnection(
        connection: clientConnection,
        retainedCapacityBudget: retainedCapacityBudget,
        incompleteFrameTimeout: incompleteFrameTimeout
    )
    do {
        try await framedConnection.startAndAwaitReady(queue: queue)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let serverConnection = acceptedConnection.value {
                return LoomFramedTCPPair(
                    listener: listener,
                    serverConnection: serverConnection,
                    framedConnection: framedConnection
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LoomFramedTCPTestError.timedOut
    } catch {
        listener.cancel()
        await framedConnection.closeTransport()
        throw error
    }
}

private func startFramedTCPListener(
    _ listener: NWListener,
    queue: DispatchQueue
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let box = LoomFramedTCPTestContinuationBox(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.complete(.success(()))
            case let .failed(error):
                box.complete(.failure(error))
            case .cancelled:
                box.complete(.failure(LoomFramedTCPTestError.cancelled))
            default:
                break
            }
        }
        listener.start(queue: queue)
    }
}

private func sendTCPFrame(
    _ payload: Data,
    over connection: NWConnection
) async throws {
    try await sendTCPBytes(frameHeader(payloadLength: payload.count) + payload, over: connection)
}

private func sendTCPBytes(
    _ data: Data,
    over connection: NWConnection
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }
}

private final class LoomFramedTCPTestContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class LoomFramedTCPTestValueBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
