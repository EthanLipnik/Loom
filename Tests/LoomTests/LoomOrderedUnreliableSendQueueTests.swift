//
//  LoomOrderedUnreliableSendQueueTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/30/26.
//

@testable import Loom
import Dispatch
import Foundation
import Network
import Testing

@Suite("Ordered Unreliable Send Queue", .serialized)
struct LoomOrderedUnreliableSendQueueTests {
    @Test("Queued sends are submitted in order without waiting for earlier completions")
    func queuedSendsSubmitInOrderWithoutWaitingForCompletion() async throws {
        let recorder = SubmissionRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.ordered-unreliable.send", qos: .userInitiated),
            sendOperation: { data, completion in
                recorder.record(data, completion: completion)
            }
        )

        let first = Data("first".utf8)
        let second = Data("second".utf8)

        queue.enqueue(first) { _ in }
        queue.enqueue(second) { _ in }

        try await waitUntil("both queued sends submitted") {
            recorder.submittedCount == 2
        }

        #expect(recorder.submittedPayloads == [first, second])

        recorder.completeSubmission(at: 0, with: nil)
        recorder.completeSubmission(at: 1, with: nil)
    }

    @Test("Queued sends stop submitting when outstanding budget is full and resume on completion")
    func queuedSendsRespectOutstandingBudget() async throws {
        let recorder = SubmissionRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.ordered-unreliable.budget", qos: .userInitiated),
            maxOutstandingPackets: 2,
            maxOutstandingBytes: 64 * 1024,
            sendOperation: { data, completion in
                recorder.record(data, completion: completion)
            }
        )

        let first = Data(repeating: 0x01, count: 1200)
        let second = Data(repeating: 0x02, count: 1200)
        let third = Data(repeating: 0x03, count: 1200)

        queue.enqueue(first) { _ in }
        queue.enqueue(second) { _ in }
        queue.enqueue(third) { _ in }

        try await waitUntil("budget-limited initial submissions") {
            recorder.submittedCount == 2
        }
        #expect(recorder.submittedPayloads == [first, second])

        recorder.completeSubmission(at: 0, with: nil)

        try await waitUntil("third submission released after completion") {
            recorder.submittedCount == 3
        }
        #expect(recorder.submittedPayloads == [first, second, third])

        recorder.completeSubmission(at: 1, with: nil)
        recorder.completeSubmission(at: 2, with: nil)
    }

    @Test("Queued sends surface connection failures through completion callbacks")
    func queuedSendsSurfaceFailures() async throws {
        let failure = AsyncResultBox<Error?>()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.ordered-unreliable.failure", qos: .userInitiated),
            sendOperation: { _, completion in
                completion(.posix(.ENETDOWN))
            }
        )

        queue.enqueue(Data("failure".utf8)) { error in
            Task {
                await failure.set(error)
            }
        }

        let error = try #require(await failure.take(timeoutSeconds: 1.0))
        let nwError = try #require(error as? NWError)
        guard case .posix(let code) = nwError else {
            Issue.record("Expected NWError.posix, got \(nwError)")
            return
        }
        #expect(code == .ENETDOWN)
    }

    @Test("Default outstanding window does not packet-cap small local media bursts")
    func defaultOutstandingWindowDoesNotPacketCapSmallMediaBursts() async throws {
        let recorder = SubmissionRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.ordered-unreliable.defaults", qos: .userInitiated),
            sendOperation: { data, completion in
                recorder.record(data, completion: completion)
            }
        )

        let packets = (0 ..< 64).map { index in
            Data(repeating: UInt8(index & 0xFF), count: 1200)
        }
        for packet in packets {
            queue.enqueue(packet) { _ in }
        }

        try await waitUntil("default queue submits the entire burst") {
            recorder.submittedCount == packets.count
        }

        #expect(recorder.submittedPayloads == packets)

        for index in packets.indices {
            recorder.completeSubmission(at: index, with: nil)
        }
    }

    @Test("Closing queue fails pending sends promptly")
    func closingQueueFailsPendingSendsPromptly() async throws {
        let recorder = SubmissionRecorder()
        let gate = DispatchSemaphore(value: 0)
        let firstResult = AsyncResultBox<Error?>()
        let secondResult = AsyncResultBox<Error?>()

        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.ordered-unreliable.close", qos: .userInitiated),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 64 * 1024,
            sendOperation: { data, completion in
                recorder.record(data, completion: completion)
                if recorder.submittedCount == 1 {
                    _ = gate.wait(timeout: .now() + 1.0)
                    completion(nil)
                }
            }
        )

        queue.enqueue(Data("first".utf8)) { error in
            Task {
                await firstResult.set(error)
            }
        }
        queue.enqueue(Data("second".utf8)) { error in
            Task {
                await secondResult.set(error)
            }
        }

        try await waitUntil("first queued send submitted") {
            recorder.submittedCount == 1
        }

        queue.close()
        gate.signal()

        _ = await firstResult.take(timeoutSeconds: 1.0)
        let secondError = try #require(await secondResult.take(timeoutSeconds: 1.0))
        let nwError = try #require(secondError as? NWError)
        guard case .posix(let code) = nwError else {
            Issue.record("Expected NWError.posix, got \(nwError)")
            return
        }
        #expect(code == .ECANCELED)
    }
}

private final class SubmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [Data] = []
    private var completions: [@Sendable (NWError?) -> Void] = []

    func record(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        lock.lock()
        submissions.append(data)
        completions.append(completion)
        lock.unlock()
    }

    var submittedCount: Int {
        lock.lock()
        let count = submissions.count
        lock.unlock()
        return count
    }

    var submittedPayloads: [Data] {
        lock.lock()
        let payloads = submissions
        lock.unlock()
        return payloads
    }

    func completeSubmission(at index: Int, with error: NWError?) {
        lock.lock()
        guard completions.indices.contains(index) else {
            lock.unlock()
            return
        }
        let completion = completions[index]
        lock.unlock()
        completion(error)
    }
}

private actor AsyncResultBox<Value: Sendable> {
    private var value: Value?

    func set(_ newValue: Value) {
        value = newValue
    }

    func take(timeoutSeconds: TimeInterval) async -> Value? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while value == nil, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return value
    }
}

private func waitUntil(
    _ description: String,
    timeoutSeconds: TimeInterval = 1.0,
    condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
    while !condition(), CFAbsoluteTimeGetCurrent() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    if !condition() {
        Issue.record("Timed out waiting for \(description)")
    }
}
