//
//  LoomSerializedNetworkSendQueueTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
@testable import Loom
import LoomNetworking
import Testing

@Suite("Serialized Network Send Queue")
struct LoomSerializedNetworkSendQueueTests {
    @Test("Queued backend sends remain ordered across async suspension")
    func queuedSendsRemainOrdered() async throws {
        let connection = DelayedSendConnection()
        let sender = LoomSerializedNetworkSendQueue(connection: connection)
        let completionProbe = SendCompletionProbe(expectedCount: 24)

        for value in 0 ..< 24 {
            sender.enqueue(Data([UInt8(value)])) { error in
                completionProbe.record(error: error)
            }
        }

        #expect(completionProbe.wait(timeout: 5))
        #expect(completionProbe.errors.isEmpty)
        let snapshot = await connection.snapshot
        #expect(snapshot.values == Array(0 ..< 24))
        #expect(snapshot.maximumConcurrentSendCount == 1)
        sender.close()
    }
}

private actor DelayedSendConnection: LoomNetworkConnection {
    nonisolated let transportKind = LoomNetworking.LoomTransportKind.udp
    nonisolated let remoteEndpoint = LoomNetworkEndpoint.hostPort(
        host: LoomNetworkHost("127.0.0.1"),
        port: 9
    )

    private var values: [Int] = []
    private var activeSendCount = 0
    private var maximumConcurrentSendCount = 0

    var localEndpoint: LoomNetworkEndpoint? {
        get async { nil }
    }

    func start() async throws {}

    func send(_ data: Data) async throws {
        activeSendCount += 1
        maximumConcurrentSendCount = max(maximumConcurrentSendCount, activeSendCount)
        defer { activeSendCount -= 1 }
        guard let value = data.first else {
            throw LoomNetworkError(code: .other, detail: "Test send was empty.")
        }
        try await Task.sleep(for: value.isMultiple(of: 2) ? .milliseconds(3) : .milliseconds(1))
        values.append(Int(value))
    }

    func receive(maximumBytes _: Int) async throws -> Data? {
        nil
    }

    func makeEventStream() async -> AsyncStream<LoomNetworkConnectionEvent> {
        AsyncStream { $0.finish() }
    }

    func cancel() async {}

    var snapshot: (values: [Int], maximumConcurrentSendCount: Int) {
        (values, maximumConcurrentSendCount)
    }
}

private final class SendCompletionProbe: @unchecked Sendable {
    private let expectedCount: Int
    private let condition = NSCondition()
    private var completionCount = 0
    private var recordedErrors: [String] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func record(error: Error?) {
        condition.lock()
        if let error {
            recordedErrors.append(String(describing: error))
        }
        completionCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while completionCount < expectedCount {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    var errors: [String] {
        condition.lock()
        defer { condition.unlock() }
        return recordedErrors
    }
}
