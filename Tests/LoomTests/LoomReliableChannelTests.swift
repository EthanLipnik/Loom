//
//  LoomReliableChannelTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import Loom
import Dispatch
import Foundation
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

    @Test("Reliable packets still fail after an absolute packet lifetime even with recent inbound traffic")
    func respectsAbsolutePacketLifetime() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 15.1,
            lastInboundPacketAge: 0.1,
            recentInboundGrace: 5.0,
            maximumPacketLifetime: 15.0
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
