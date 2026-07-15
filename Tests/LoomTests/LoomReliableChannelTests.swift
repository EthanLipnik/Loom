//
//  LoomReliableChannelTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import Loom
import Dispatch
import Foundation
import LoomNetworking
import Network
import Testing

@Suite("Reliable Channel Transport Policy")
struct LoomReliableChannelTests {
    @Test("Reliable packets fail once retries are exhausted and the peer is no longer active")
    func timesOutWhenRetryBudgetIsExhaustedWithoutRecentInboundTraffic() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 6.0,
            lastInboundPacketAge: 6.0,
            recentInboundGrace: 5.0,
            maximumPacketLifetime: 15.0
        )

        #expect(shouldFail)
    }

    @Test("Reliable packets stay alive past the retry budget while inbound traffic is still flowing")
    func defersTimeoutWhileRecentInboundTrafficContinues() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 6.0,
            lastInboundPacketAge: 0.2,
            recentInboundGrace: 5.0,
            maximumPacketLifetime: 15.0
        )

        #expect(!shouldFail)
    }

    @Test("Reliable packets stay alive across short idle gaps after recent peer traffic")
    func defersTimeoutDuringShortIdleGapAfterRecentInboundTraffic() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 12.0,
            lastInboundPacketAge: 11.0,
            recentInboundGrace: 20.0,
            maximumPacketLifetime: 30.0
        )

        #expect(!shouldFail)
    }

    @Test("Reliable packets still fail after an absolute packet lifetime even with recent inbound traffic")
    func respectsAbsolutePacketLifetime() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 30.1,
            lastInboundPacketAge: 0.1,
            recentInboundGrace: 20.0,
            maximumPacketLifetime: 30.0
        )

        #expect(shouldFail)
    }

    @Test("Reliable ingress sends an immediate ack after an idle gap")
    func sendsImmediateAckAfterIdleGap() {
        let now: CFAbsoluteTime = 100.0

        #expect(
            LoomReliableChannel.shouldSendImmediateReliableAck(
                lastAckSentAt: nil,
                now: now,
                idleThreshold: 0.05
            )
        )

        #expect(
            LoomReliableChannel.shouldSendImmediateReliableAck(
                lastAckSentAt: now - 0.06,
                now: now,
                idleThreshold: 0.05
            )
        )

        #expect(
            !LoomReliableChannel.shouldSendImmediateReliableAck(
                lastAckSentAt: now - 0.01,
                now: now,
                idleThreshold: 0.05
            )
        )
    }

    @Test("Queued media sends keep scheduled reliable acks alive")
    func queuedMediaSendsKeepScheduledReliableAcksAlive() async throws {
        let networkQueue = DispatchQueue(label: "loom.tests.reliable-channel.ack-starvation")
        let serverBox = LoomReliableChannelTestBox()
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            let channel = LoomReliableChannel(connection: connection)
            serverBox.store(channel)
            Task {
                do {
                    try await channel.startAndAwaitReady(queue: networkQueue)
                } catch {
                    serverBox.fail(error)
                }
            }
        }
        try await startAndAwaitReady(listener, queue: networkQueue)
        guard let port = listener.port else {
            throw LoomReliableChannelTestError.listenerPortUnavailable
        }

        let client = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        try await startAndAwaitReady(client, queue: networkQueue)
        defer {
            client.cancel()
            listener.cancel()
        }

        try await sendReliableDatagram(
            Data([0]),
            sequence: 0,
            flags: [.reliable, .hello],
            over: client
        )
        let server = try await waitForServerChannel(serverBox)
        let firstPayload = try await awaitValue(timeout: .seconds(1)) {
            try await server.receiveHandshakeMessage(maxBytes: 16)
        }
        #expect(firstPayload == Data([0]))

        let secondPayloadTask = Task {
            try await server.receiveHandshakeMessage(maxBytes: 16)
        }
        try await sendReliableDatagram(
            Data([1]),
            sequence: 1,
            flags: [.reliable, .hello],
            over: client
        )
        let secondPayload = try await awaitValue(from: secondPayloadTask, timeout: .seconds(1))
        #expect(secondPayload == Data([1]))

        await server.sendUnreliableQueued(
            Data(repeating: 0xEE, count: 64),
            profile: .interactiveMedia,
            options: .none
        ) { _ in }

        let ack = try await receiveAckOnly(
            over: client,
            ackSequenceAtLeast: 1,
            timeout: .seconds(1)
        )
        #expect(ack.ackSequence >= 1)

        await server.close()
    }

    @Test("Native queued media sends preserve the profile concurrency window")
    func nativeQueuedMediaSendsRemainConcurrent() async throws {
        let connection = LoomConcurrentQueuedSendTestConnection()
        let channel = LoomReliableChannel(connection: connection)
        let completionCounter = LoomReliableChannelTestCounter()
        defer {
            Task { await channel.closeTransport() }
        }

        for value in 0 ..< 64 {
            await channel.sendUnreliableQueued(
                Data([UInt8(value)]),
                profile: .interactiveMedia,
                options: .none
            ) { error in
                #expect(error == nil)
                completionCounter.increment()
            }
        }

        try await waitForCount(completionCounter, expected: 64)
        #expect(connection.maximumConcurrentSendCount > 1)
    }

    @Test("Native framed media sends preserve the profile concurrency window")
    func nativeFramedQueuedMediaSendsRemainConcurrent() async throws {
        let connection = LoomConcurrentQueuedSendTestConnection(transportKind: .tcp)
        let framedConnection = LoomFramedConnection(connection: connection)
        let completionCounter = LoomReliableChannelTestCounter()
        defer {
            Task { await framedConnection.closeTransport() }
        }

        for value in 0 ..< 64 {
            await framedConnection.sendUnreliableQueued(
                Data([UInt8(value)]),
                profile: .interactiveMedia,
                options: .none
            ) { error in
                #expect(error == nil)
                completionCounter.increment()
            }
        }

        try await waitForCount(completionCounter, expected: 64)
        #expect(connection.maximumConcurrentSendCount > 1)
    }

    @Test("Multi-fragment handshake messages round-trip without leaking retained capacity")
    func multiFragmentHandshakeRoundTrip() async throws {
        let networkQueue = DispatchQueue(label: "loom.tests.reliable-channel.fragments")
        let serverBox = LoomReliableChannelTestBox()
        let retainedCapacityBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: LoomMessageLimits.maxReceiveBufferBytes,
            maximumPayloadCount: 64,
            maximumBatchCount: 64
        )
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            let channel = LoomReliableChannel(
                connection: connection,
                retainedCapacityBudget: retainedCapacityBudget
            )
            serverBox.store(channel)
            Task {
                do {
                    try await channel.startAndAwaitReady(queue: networkQueue)
                } catch {
                    serverBox.fail(error)
                }
            }
        }
        try await startAndAwaitReady(listener, queue: networkQueue)
        let port = try #require(listener.port)

        let client = LoomReliableChannel(
            connection: NWConnection(host: "127.0.0.1", port: port, using: .udp)
        )
        try await client.startAndAwaitReady(queue: networkQueue)
        defer {
            listener.cancel()
            Task {
                await client.close()
                await serverBox.channel?.close()
            }
        }

        let payload = Data(
            (0 ..< (loomReliableMaxFragmentPayload * 3 + 17)).map { UInt8($0 % 251) }
        )
        let receiveTask = Task {
            let server = try await waitForServerChannel(serverBox)
            return try await server.receiveHandshakeMessage(maxBytes: payload.count)
        }
        try await client.sendHandshakeMessage(payload)

        #expect(try await awaitValue(from: receiveTask, timeout: .seconds(2)) == payload)
        #expect(retainedCapacityBudget.retainedBytesForTesting == 0)
    }

    @Test("Concurrent reliable sends preserve contiguous fragment sequence ranges")
    func concurrentReliableSendsPreserveFragmentSequenceRanges() async throws {
        let connection = LoomSuspendingReliableSendTestConnection()
        let channel = LoomReliableChannel(connection: connection)
        let payload = Data(repeating: 0xAA, count: loomReliableMaxFragmentPayload * 3 + 17)

        let fragmentedSend = Task {
            try await channel.sendMessage(payload)
        }
        try await connection.waitForSendCount(1)

        let concurrentSend = Task {
            try await channel.sendMessage(Data([0xBB]))
        }
        try await connection.waitForSendCount(2)
        await connection.resumeFirstSend()

        try await fragmentedSend.value
        try await concurrentSend.value

        let sentPackets = await connection.sentPackets
        let fragmentHeaders = sentPackets
            .compactMap { LoomReliablePacketHeader.deserialize(from: $0) }
            .filter { $0.flags.contains(.fragment) }
            .sorted { $0.fragmentIndex < $1.fragmentIndex }
        let firstSequence = try #require(fragmentHeaders.first?.sequence)

        #expect(fragmentHeaders.count == 4)
        #expect(fragmentHeaders.map(\.sequence) == (0..<4).map { firstSequence &+ UInt32($0) })
    }

    @Test("Unauthenticated unreliable datagrams do not consume retained capacity")
    func dropsPreauthenticationUnreliableDatagrams() async throws {
        let networkQueue = DispatchQueue(label: "loom.tests.reliable-channel.preauth-drop")
        let serverBox = LoomReliableChannelTestBox()
        let retainedCapacityBudget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 4,
            maximumPayloadCount: 1,
            maximumBatchCount: 1
        )
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            let channel = LoomReliableChannel(
                connection: connection,
                retainedCapacityBudget: retainedCapacityBudget
            )
            serverBox.store(channel)
            Task {
                do {
                    try await channel.startAndAwaitReady(queue: networkQueue)
                } catch {
                    serverBox.fail(error)
                }
            }
        }
        try await startAndAwaitReady(listener, queue: networkQueue)
        let port = try #require(listener.port)
        let client = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        try await startAndAwaitReady(client, queue: networkQueue)
        defer {
            client.cancel()
            listener.cancel()
            Task { await serverBox.channel?.close() }
        }

        try await sendDatagram(
            LoomReliablePacketHeader(payloadLength: 32).serialize() + Data(repeating: 0xAA, count: 32),
            over: client
        )
        let server = try await waitForServerChannel(serverBox)
        try await Task.sleep(for: .milliseconds(50))
        #expect(retainedCapacityBudget.retainedBytesForTesting == 0)

        let receiveTask = Task {
            try await server.receiveHandshakeMessage(maxBytes: 4)
        }
        try await sendReliableDatagram(
            Data([1]),
            sequence: 0,
            flags: [.reliable, .hello],
            over: client
        )
        #expect(try await awaitValue(from: receiveTask, timeout: .seconds(1)) == Data([1]))

        let trustStatusTask = Task {
            try await server.receiveHandshakeMessage(maxBytes: 4)
        }
        try await sendReliableDatagram(
            Data([2]),
            sequence: 1,
            flags: [.reliable, .hello],
            over: client
        )
        #expect(try await awaitValue(from: trustStatusTask, timeout: .seconds(1)) == Data([2]))
        try await sendDatagram(
            LoomReliablePacketHeader(payloadLength: 32).serialize() + Data(repeating: 0xBB, count: 32),
            over: client
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(retainedCapacityBudget.retainedBytesForTesting == 0)
    }

    @Test("Post-handshake hello packets fail closed instead of stalling ordered delivery")
    func rejectsPostHandshakeHello() async throws {
        let networkQueue = DispatchQueue(label: "loom.tests.reliable-channel.late-hello")
        let serverBox = LoomReliableChannelTestBox()
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            let channel = LoomReliableChannel(connection: connection)
            serverBox.store(channel)
            Task {
                do {
                    try await channel.startAndAwaitReady(queue: networkQueue)
                } catch {
                    serverBox.fail(error)
                }
            }
        }
        try await startAndAwaitReady(listener, queue: networkQueue)
        let port = try #require(listener.port)
        let client = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        try await startAndAwaitReady(client, queue: networkQueue)
        defer {
            client.cancel()
            listener.cancel()
            Task { await serverBox.channel?.close() }
        }

        try await sendReliableDatagram(
            Data([0]),
            sequence: 0,
            flags: [.reliable, .hello],
            over: client
        )
        let server = try await waitForServerChannel(serverBox)
        #expect(try await server.receiveHandshakeMessage(maxBytes: 4) == Data([0]))

        let receiveTask = Task {
            try await server.receiveMessage(maxBytes: 4)
        }
        await Task.yield()
        try await sendReliableDatagram(
            Data([1]),
            sequence: 1,
            flags: [.reliable, .hello],
            over: client
        )

        do {
            _ = try await awaitValue(from: receiveTask, timeout: .seconds(1))
            Issue.record("Post-handshake hello was accepted.")
        } catch LoomReliableChannelTestError.timedOut {
            Issue.record("Post-handshake hello stalled ordered delivery instead of failing closed.")
        } catch {
            // Expected terminal protocol failure.
        }
    }

    @Test("Post-handshake ordering starts after the accepted hello sequence")
    func preservesFirstPostHandshakeSequenceAcrossEarlyArrival() async throws {
        let networkQueue = DispatchQueue(label: "loom.tests.reliable-channel.handshake-transition")
        let serverBox = LoomReliableChannelTestBox()
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            let channel = LoomReliableChannel(connection: connection)
            serverBox.store(channel)
            Task {
                do {
                    try await channel.startAndAwaitReady(queue: networkQueue)
                } catch {
                    serverBox.fail(error)
                }
            }
        }
        try await startAndAwaitReady(listener, queue: networkQueue)
        let port = try #require(listener.port)
        let client = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        try await startAndAwaitReady(client, queue: networkQueue)
        defer {
            client.cancel()
            listener.cancel()
            Task { await serverBox.channel?.close() }
        }

        try await sendReliableDatagram(
            Data([0]),
            sequence: 0,
            flags: [.reliable, .hello],
            over: client
        )
        let server = try await waitForServerChannel(serverBox)
        #expect(try await server.receiveHandshakeMessage(maxBytes: 4) == Data([0]))

        let firstReceive = Task {
            try await server.receiveMessage(maxBytes: 4)
        }
        await Task.yield()
        try await sendReliableDatagram(
            Data([2]),
            sequence: 2,
            flags: [.reliable],
            over: client
        )
        try await sendReliableDatagram(
            Data([1]),
            sequence: 1,
            flags: [.reliable],
            over: client
        )

        #expect(try await awaitValue(from: firstReceive, timeout: .seconds(1)) == Data([1]))
        #expect(try await server.receiveMessage(maxBytes: 4) == Data([2]))
    }

    @Test("Outbound reliable packets fail closed when the acknowledgement window is full")
    func boundsPendingAcknowledgements() async throws {
        let networkQueue = DispatchQueue(label: "loom.tests.reliable-channel.pending-acks")
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: networkQueue)
        }
        try await startAndAwaitReady(listener, queue: networkQueue)
        let port = try #require(listener.port)
        let channel = LoomReliableChannel(
            connection: NWConnection(host: "127.0.0.1", port: port, using: .udp),
            maximumPendingReliablePackets: 2,
            maximumPendingReliableBytes: 1_024
        )
        try await channel.startAndAwaitReady(queue: networkQueue)
        defer {
            listener.cancel()
            Task { await channel.close() }
        }

        try await channel.sendMessage(Data([1]))
        try await channel.sendMessage(Data([2]))
        await #expect(throws: LoomError.self) {
            try await channel.sendMessage(Data([3]))
        }
    }

    @Test(
        "Unreliable delivery lane saturation does not close the reliable UDP session",
        arguments: LoomNetworkFrameworkDatagramReceiveStrategy.allCases
    )
    func keepsSessionAliveWhenUnreliableDeliverySaturates(
        strategy: LoomNetworkFrameworkDatagramReceiveStrategy
    ) async throws {
        let networkQueue = DispatchQueue(label: "loom.tests.reliable-channel.unreliable-saturation")
        let serverBox = LoomReliableChannelTestBox()
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            let channel = LoomReliableChannel(
                connection: connection,
                datagramReceiveStrategy: strategy
            )
            serverBox.store(channel)
            Task {
                do {
                    try await channel.startAndAwaitReady(queue: networkQueue)
                } catch {
                    serverBox.fail(error)
                }
            }
        }
        try await startAndAwaitReady(listener, queue: networkQueue)
        let port = try #require(listener.port)
        let client = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        try await startAndAwaitReady(client, queue: networkQueue)
        defer {
            client.cancel()
            listener.cancel()
            Task { await serverBox.channel?.close() }
        }

        try await sendReliableDatagram(
            Data([0]),
            sequence: 0,
            flags: [.reliable, .hello],
            over: client
        )
        let server = try await waitForServerChannel(serverBox)
        #expect(try await server.receiveHandshakeMessage(maxBytes: 4) == Data([0]))
        try await server.prepareUnreliableReceive(maxBytes: 64)

        let mediaBurstPayloadCount = LoomMessageLimits.maxBufferedPayloadsPerStream * 2
        for value in 0 ..< mediaBurstPayloadCount {
            let payload = Data([
                LoomSessionTrafficClass.data.rawValue,
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
            ])
            try await sendDatagram(
                LoomReliablePacketHeader(payloadLength: UInt16(payload.count)).serialize() + payload,
                over: client
            )
        }

        var receivedValues: [Int] = []
        for _ in 0 ..< mediaBurstPayloadCount {
            let payload = try await server.receiveUnreliable(maxBytes: 64)
            receivedValues.append(Int(payload[1]) | Int(payload[2]) << 8)
        }
        #expect(receivedValues == Array(0 ..< mediaBurstPayloadCount))

        for value in 0 ..< (LoomMessageLimits.maxBufferedPayloadsPerStream + 64) {
            let payload = Data([
                LoomSessionTrafficClass.priorityInput.rawValue,
                UInt8(truncatingIfNeeded: value),
            ])
            try await sendDatagram(
                LoomReliablePacketHeader(payloadLength: UInt16(payload.count)).serialize() + payload,
                over: client
            )
        }

        let reliableReceive = Task {
            try await server.receiveMessage(maxBytes: 4)
        }
        try await sendReliableDatagram(
            Data([1]),
            sequence: 1,
            flags: [.reliable],
            over: client
        )

        #expect(try await awaitValue(from: reliableReceive, timeout: .seconds(1)) == Data([1]))
    }
}

private enum LoomReliableChannelTestError: Error {
    case connectionCancelled
    case listenerPortUnavailable
    case noDatagram
    case timedOut
}

private func startAndAwaitReady(_ listener: NWListener, queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let box = LoomReliableChannelTestContinuationBox(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.complete(.success(()))
            case .failed(let error):
                box.complete(.failure(error))
            case .cancelled:
                box.complete(.failure(LoomReliableChannelTestError.connectionCancelled))
            default:
                break
            }
        }
        listener.start(queue: queue)
    }
}

private func startAndAwaitReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let box = LoomReliableChannelTestContinuationBox(continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.complete(.success(()))
            case .failed(let error):
                box.complete(.failure(error))
            case .cancelled:
                box.complete(.failure(LoomReliableChannelTestError.connectionCancelled))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

private func waitForServerChannel(
    _ box: LoomReliableChannelTestBox,
    timeout: Duration = .seconds(1)
) async throws -> LoomReliableChannel {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let channel = box.channel {
            return channel
        }
        if let error = box.error {
            throw error
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LoomReliableChannelTestError.timedOut
}

private func sendReliableDatagram(
    _ payload: Data,
    sequence: UInt32,
    flags: LoomReliablePacketFlags,
    over connection: NWConnection
) async throws {
    let header = LoomReliablePacketHeader(
        flags: flags,
        sequence: sequence,
        payloadLength: UInt16(payload.count)
    )
    try await sendDatagram(header.serialize() + payload, over: connection)
}

private func sendDatagram(_ data: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let box = LoomReliableChannelTestContinuationBox(continuation)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                box.complete(.failure(error))
            } else {
                box.complete(.success(()))
            }
        })
    }
}

private func receiveAckOnly(
    over connection: NWConnection,
    ackSequenceAtLeast expectedAckSequence: UInt32,
    timeout: Duration
) async throws -> LoomReliablePacketHeader {
    for _ in 0 ..< 6 {
        let data = try await receiveDatagram(over: connection, timeout: timeout)
        guard let header = LoomReliablePacketHeader.deserialize(from: data) else {
            continue
        }
        if header.flags.contains(.ackOnly), header.ackSequence >= expectedAckSequence {
            return header
        }
    }
    throw LoomReliableChannelTestError.timedOut
}

private func receiveDatagram(over connection: NWConnection, timeout: Duration) async throws -> Data {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        let box = LoomReliableChannelTestContinuationBox(continuation)
        connection.receiveMessage { data, _, _, error in
            if let error {
                box.complete(.failure(error))
                return
            }
            guard let data else {
                box.complete(.failure(LoomReliableChannelTestError.noDatagram))
                return
            }
            box.complete(.success(data))
        }
        Task {
            try? await Task.sleep(for: timeout)
            box.complete(.failure(LoomReliableChannelTestError.timedOut))
        }
    }
}

private func awaitValue<Value: Sendable>(
    timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let task = Task {
        try await operation()
    }
    return try await awaitValue(from: task, timeout: timeout)
}

private func awaitValue<Value: Sendable>(
    from task: Task<Value, Error>,
    timeout: Duration
) async throws -> Value {
    defer {
        task.cancel()
    }
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LoomReliableChannelTestError.timedOut
        }
        guard let value = try await group.next() else {
            throw LoomReliableChannelTestError.timedOut
        }
        group.cancelAll()
        return value
    }
}

private final class LoomReliableChannelTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channelStorage: LoomReliableChannel?
    private var errorStorage: Error?

    var channel: LoomReliableChannel? {
        lock.lock()
        defer { lock.unlock() }
        return channelStorage
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }

    func store(_ channel: LoomReliableChannel) {
        lock.lock()
        channelStorage = channel
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        errorStorage = error
        lock.unlock()
    }
}

private final class LoomReliableChannelTestContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class LoomReliableChannelTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LoomConcurrentQueuedSendTestConnection: LoomConcurrentQueuedSendConnection, @unchecked Sendable {
    let transportKind: LoomNetworking.LoomTransportKind
    let remoteEndpoint = LoomNetworkEndpoint.opaque(description: "concurrent-send-test")
    var localEndpoint: LoomNetworkEndpoint? { get async { nil } }
    var currentPath: LoomNetworkPath? { get async { nil } }

    private let lock = NSLock()
    private var activeSendCount = 0
    private var maximumConcurrentSendCountStorage = 0

    init(transportKind: LoomNetworking.LoomTransportKind = .udp) {
        self.transportKind = transportKind
    }

    var maximumConcurrentSendCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumConcurrentSendCountStorage
    }

    func start() async throws {}

    func send(_ data: Data) async throws {
        _ = data
    }

    func sendQueued(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        _ = data
        lock.lock()
        activeSendCount += 1
        maximumConcurrentSendCountStorage = max(maximumConcurrentSendCountStorage, activeSendCount)
        lock.unlock()

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(10))
            self?.completeSend(completion)
        }
    }

    private func completeSend(_ completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        activeSendCount -= 1
        lock.unlock()
        completion(nil)
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        _ = maximumBytes
        return nil
    }

    func makeEventStream() async -> AsyncStream<LoomNetworkConnectionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func cancel() async {}
}

private actor LoomSuspendingReliableSendTestConnection: LoomNetworkConnection {
    nonisolated let transportKind = LoomNetworking.LoomTransportKind.udp
    nonisolated let remoteEndpoint = LoomNetworkEndpoint.opaque(description: "suspending-reliable-send-test")
    var localEndpoint: LoomNetworkEndpoint? { get async { nil } }
    var currentPath: LoomNetworkPath? { get async { nil } }

    private var packets: [Data] = []
    private var firstSendContinuation: CheckedContinuation<Void, Never>?

    var sentPackets: [Data] {
        packets
    }

    func start() async throws {}

    func send(_ data: Data) async throws {
        packets.append(data)
        guard packets.count == 1 else { return }
        await withCheckedContinuation { continuation in
            firstSendContinuation = continuation
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        _ = maximumBytes
        return nil
    }

    func makeEventStream() async -> AsyncStream<LoomNetworkConnectionEvent> {
        AsyncStream { $0.finish() }
    }

    func cancel() async {}

    func waitForSendCount(_ expectedCount: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while packets.count < expectedCount {
            guard ContinuousClock.now < deadline else {
                throw LoomReliableChannelTestError.timedOut
            }
            await Task.yield()
        }
    }

    func resumeFirstSend() {
        firstSendContinuation?.resume()
        firstSendContinuation = nil
    }
}

private func waitForCount(
    _ counter: LoomReliableChannelTestCounter,
    expected: Int,
    timeout: Duration = .seconds(1)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if counter.value >= expected {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw LoomReliableChannelTestError.timedOut
}
