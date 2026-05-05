//
//  LoomOrderedUnreliableSendQueueTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import Loom
import Dispatch
import Foundation
import Testing

@Suite("Loom Ordered Unreliable Send Queue")
struct LoomOrderedUnreliableSendQueueTests {
    @Test("Throughput probe queue accepts more outstanding packets before backpressure")
    func throughputProbeQueueAcceptsDeeperBurst() async throws {
        let packetSize = 1024
        let payload = Data(repeating: 0xAB, count: packetSize)
        let interactiveLimits = LoomOrderedUnreliableSendQueue.limits(for: .interactiveMedia)
        let throughputLimits = LoomOrderedUnreliableSendQueue.limits(for: .throughputProbe)
        let interactiveCounter = LockedCounter()
        let throughputCounter = LockedCounter()

        let interactiveQueue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.interactive"),
            maxOutstandingPackets: interactiveLimits.maxOutstandingPackets,
            maxOutstandingBytes: interactiveLimits.maxOutstandingBytes,
            sendOperation: { _, _ in
                interactiveCounter.increment()
            }
        )
        let throughputQueue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.probe"),
            maxOutstandingPackets: throughputLimits.maxOutstandingPackets,
            maxOutstandingBytes: throughputLimits.maxOutstandingBytes,
            sendOperation: { _, _ in
                throughputCounter.increment()
            }
        )

        let interactiveAttemptCount = interactiveLimits.maxOutstandingPackets + 64
        let throughputAttemptCount = interactiveAttemptCount + 2_048

        for _ in 0 ..< interactiveAttemptCount {
            interactiveQueue.enqueue(payload) { _ in }
        }
        for _ in 0 ..< throughputAttemptCount {
            throughputQueue.enqueue(payload) { _ in }
        }

        try await waitForCounter(
            interactiveCounter,
            expected: interactiveLimits.maxOutstandingPackets
        )
        try await waitForCounter(
            throughputCounter,
            expected: throughputAttemptCount
        )

        #expect(interactiveCounter.value == interactiveLimits.maxOutstandingPackets)
        #expect(throughputCounter.value == throughputAttemptCount)

        interactiveQueue.close()
        throughputQueue.close()
    }

    @Test("Stream reset forwards only the selected queued-unreliable profile")
    func streamResetForwardsOnlySelectedQueuedUnreliableProfile() async {
        let recorder = ResetProfileRecorder()
        let stream = LoomMultiplexedStream(
            id: 7,
            label: "quality-test/reset",
            sendHandler: { _ in },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, onComplete in
                onComplete(nil)
            },
            queuedUnreliableResetHandler: { profile in
                recorder.record(profile)
            },
            closeHandler: {}
        )

        await stream.resetQueuedUnreliableSends(profile: .throughputProbe)

        #expect(recorder.recordedProfiles == [.throughputProbe])
    }

    private func waitForCounter(
        _ counter: LockedCounter,
        expected: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if counter.value >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for queued sends to reach \(expected); saw \(counter.value)")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class ResetProfileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LoomQueuedUnreliableSendProfile] = []

    var recordedProfiles: [LoomQueuedUnreliableSendProfile] {
        lock.lock()
        let profiles = storage
        lock.unlock()
        return profiles
    }

    func record(_ profile: LoomQueuedUnreliableSendProfile) {
        lock.lock()
        storage.append(profile)
        lock.unlock()
    }
}
