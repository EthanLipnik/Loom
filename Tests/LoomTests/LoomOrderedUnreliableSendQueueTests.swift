//
//  LoomOrderedUnreliableSendQueueTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import Loom
import Dispatch
import Foundation
import Network
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

    @Test("Interactive audio profile keeps a shallow independent media queue")
    func interactiveAudioProfileUsesShallowIndependentQueue() {
        let videoLimits = LoomQueuedUnreliableSendProfile.interactiveMedia.recommendedLimits
        let audioLimits = LoomQueuedUnreliableSendProfile.interactiveAudio.recommendedLimits
        let proximityAudioLimits = LoomQueuedUnreliableSendProfile.proximityInteractiveAudio.recommendedLimits

        #expect(audioLimits.maxOutstandingPackets < videoLimits.maxOutstandingPackets)
        #expect(audioLimits.maxOutstandingBytes < videoLimits.maxOutstandingBytes)
        #expect(audioLimits.maxQueuedPackets == 64)
        #expect(proximityAudioLimits.maxOutstandingPackets < audioLimits.maxOutstandingPackets)
        #expect(proximityAudioLimits.maxQueuedPackets == 32)
    }

    @Test("Priority realtime queue keeps newest pending input")
    func priorityRealtimeQueueKeepsNewestPendingInput() async throws {
        let limits = LoomOrderedUnreliableSendQueue.limits(for: .priorityInputRealtime)
        let recorder = LockedSendRecorder()
        let droppedCount = LockedCounter()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.priority-input"),
            maxOutstandingPackets: limits.maxOutstandingPackets,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            replacesQueuedSends: limits.replacesQueuedSends,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1])) { _ in }
        queue.enqueue(Data([2])) { error in
            if error != nil {
                droppedCount.increment()
            }
        }
        queue.enqueue(Data([3])) { _ in }

        try await waitForCounter(droppedCount, expected: 1)
        #expect(recorder.recordedPayloads == [Data([1])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3])])

        queue.close()
    }

    @Test("Priority sequenced realtime queue keeps short FIFO input window")
    func prioritySequencedRealtimeQueueKeepsShortFIFOInputWindow() async throws {
        let limits = LoomOrderedUnreliableSendQueue.limits(for: .priorityInputRealtimeSequenced)
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.priority-input-sequenced"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            maxQueuedPackets: 2,
            replacesQueuedSends: limits.replacesQueuedSends,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1])) { _ in }
        queue.enqueue(Data([2])) { error in
            if error != nil { droppedPayloads.record(Data([2])) }
        }
        queue.enqueue(Data([3])) { error in
            if error != nil { droppedPayloads.record(Data([3])) }
        }
        queue.enqueue(Data([4])) { error in
            if error != nil { droppedPayloads.record(Data([4])) }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([2])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3]), Data([4])])

        queue.close()
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

    private func waitForRecordedPayloads(
        _ recorder: LockedSendRecorder,
        expected: [Data],
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.recordedPayloads == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for recorded payloads; saw \(recorder.recordedPayloads)")
    }

    private func waitForDroppedPayloads(
        _ recorder: LockedDataRecorder,
        expected: [Data],
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.recordedPayloads == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for dropped payloads; saw \(recorder.recordedPayloads)")
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

private final class LockedSendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloadStorage: [Data] = []
    private var completionStorage: [@Sendable (NWError?) -> Void] = []

    var recordedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloadStorage
    }

    func record(
        data: Data,
        completion: @escaping @Sendable (NWError?) -> Void
    ) {
        lock.lock()
        payloadStorage.append(data)
        completionStorage.append(completion)
        lock.unlock()
    }

    func completeNext(error: NWError?) {
        lock.lock()
        let completion = completionStorage.isEmpty ? nil : completionStorage.removeFirst()
        lock.unlock()
        completion?(error)
    }
}

private final class LockedDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloadStorage: [Data] = []

    var recordedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloadStorage
    }

    func record(_ payload: Data) {
        lock.lock()
        payloadStorage.append(payload)
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
