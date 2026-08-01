//
//  LoomQuiescingHardDeadlineTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 8/1/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Quiescing Hard Deadline")
struct LoomQuiescingHardDeadlineTests {
    @Test("Closed admission waits for every previously admitted reliable send")
    func admissionWaitsForConcurrentReliableSends() async throws {
        let admission = LoomReliableSendAdmission()
        let first = try #require(admission.acquire())
        let second = try #require(admission.acquire())
        let drainCount = HardDeadlineCounter()

        admission.close()
        #expect(admission.acquire().map { _ in false } ?? true)
        let waiter = Task {
            await admission.waitForQuiescence()
            drainCount.increment()
        }
        first.release()
        try await Task.sleep(for: .milliseconds(5))
        #expect(drainCount.value == 0)
        second.release()
        await waiter.value
        #expect(drainCount.value == 1)
    }

    @Test("Deadline admission is atomic and an expired attempt owns no lease")
    func deadlineAdmissionIsAtomic() async throws {
        let admission = LoomReliableSendAdmission()

        switch admission.acquire(before: ContinuousClock.now - .milliseconds(1)) {
        case .expired:
            break
        case .admitted,
             .closed:
            Issue.record("An elapsed deadline must not enter admission.")
        }
        #expect(admission.isOpen)

        let lease: LoomReliableSendAdmission.Lease? = switch admission.acquire(
            before: ContinuousClock.now + .seconds(1)
        ) {
        case let .admitted(lease): lease
        case .expired,
             .closed: nil
        }
        #expect(lease != nil)
        admission.close()
        switch admission.acquire(before: ContinuousClock.now + .seconds(1)) {
        case .closed:
            break
        case .admitted,
             .expired:
            Issue.record("A closed admission fence must win over a future deadline.")
        }
        lease?.release()
        await admission.waitForQuiescence()
    }

    @Test("A hard cut releases a transferred lease when its operation never starts")
    func unstartedOperationReleasesTransferredLease() async throws {
        let admission = LoomReliableSendAdmission()
        let lease = try #require(admission.acquire())
        let transfer = LoomReliableSendLeaseTransfer(lease)

        await #expect(throws: LoomError.self) {
            try await withLoomQuiescingHardDeadline(
                ContinuousClock.now - .milliseconds(1),
                closeAdmission: { admission.close() },
                releaseUnstartedOperation: { transfer.releaseIfOperationHasNotStarted() },
                quiesce: { await admission.waitForQuiescence() },
                operation: {
                    Issue.record("An elapsed deadline must not start its operation.")
                }
            )
        }
        #expect(!admission.isOpen)
    }

    @Test("An expired pre-admission deadline does not close admission")
    func expiredDeadlineIsNonDestructiveBeforeAdmission() async throws {
        let admission = LoomReliableSendAdmission()
        let transportEntries = HardDeadlineCounter()
        let stream = LoomMultiplexedStream(
            id: 1,
            label: "expired-hard-deadline",
            sendHandler: { _ in
                guard let lease = admission.acquire() else {
                    throw LoomError.protocolError("closed")
                }
                defer { lease.release() }
                transportEntries.increment()
            },
            hardDeadlineSendHandler: { _, deadline in
                guard ContinuousClock.now < deadline else { throw LoomError.timeout }
                guard let lease = admission.acquire() else { throw LoomError.protocolError("closed") }
                defer { lease.release() }
                transportEntries.increment()
            },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, _, completion in completion(nil) },
            queuedUnreliableResetHandler: { _ in },
            closeHandler: {}
        )

        await #expect(throws: LoomError.self) {
            try await stream.send(
                Data([1]),
                hardDeadline: ContinuousClock.now.advanced(by: .milliseconds(-1))
            )
        }
        #expect(admission.isOpen)
        #expect(transportEntries.value == 0)
        try await stream.send(Data([2]))
        #expect(transportEntries.value == 1)
    }

    @Test("Deadline returns only after cancellation-insensitive work terminates")
    func deadlineWaitsForOperationTermination() async throws {
        let blocker = HardDeadlineBlocker()
        let admission = LoomReliableSendAdmission()
        let closeCount = HardDeadlineCounter()
        let task = Task {
            do {
                try await withLoomQuiescingHardDeadline(
                    ContinuousClock.now + .milliseconds(20),
                    closeAdmission: {
                        admission.close()
                        closeCount.increment()
                    },
                    quiesce: {
                        await blocker.release()
                    },
                    operation: {
                        await blocker.wait()
                        await blocker.markOperationExited()
                    }
                )
                return false
            } catch LoomError.timeout {
                return true
            } catch {
                return false
            }
        }

        #expect(await waitUntil { await blocker.hasStarted })
        #expect(await task.value)
        #expect(!admission.isOpen)
        #expect(closeCount.value == 1)
        #expect(await blocker.hasExited)
    }

    @Test("Caller cancellation uses the same quiescing hard cut")
    func cancellationWaitsForOperationTermination() async throws {
        let blocker = HardDeadlineBlocker()
        let admission = LoomReliableSendAdmission()
        let task = Task {
            do {
                try await withLoomQuiescingHardDeadline(
                    ContinuousClock.now + .seconds(10),
                    closeAdmission: {
                        admission.close()
                    },
                    quiesce: {
                        await blocker.release()
                    },
                    operation: {
                        await blocker.wait()
                        await blocker.markOperationExited()
                    }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        #expect(await waitUntil { await blocker.hasStarted })
        task.cancel()
        #expect(await task.value)
        #expect(!admission.isOpen)
        #expect(await blocker.hasExited)
    }

    @Test("A hard-cut stream rejects later sends before transport entry")
    func streamRejectsSendAfterHardCut() async throws {
        let blocker = HardDeadlineBlocker()
        let admission = LoomReliableSendAdmission()
        let transportEntries = HardDeadlineCounter()
        let stream = LoomMultiplexedStream(
            id: 1,
            label: "hard-deadline",
            sendHandler: { _ in
                guard admission.isOpen else { throw LoomError.protocolError("closed") }
                transportEntries.increment()
            },
            hardDeadlineSendHandler: { _, deadline in
                guard admission.isOpen else { throw LoomError.protocolError("closed") }
                try await withLoomQuiescingHardDeadline(
                    deadline,
                    closeAdmission: {
                        admission.close()
                    },
                    quiesce: {
                        await blocker.release()
                    },
                    operation: {
                        transportEntries.increment()
                        await blocker.wait()
                        await blocker.markOperationExited()
                    }
                )
            },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, _, completion in completion(nil) },
            queuedUnreliableResetHandler: { _ in },
            closeHandler: {}
        )

        let timedSend = Task {
            await #expect(throws: LoomError.self) {
                try await stream.send(
                    Data([1]),
                    hardDeadline: ContinuousClock.now + .milliseconds(20)
                )
            }
        }
        #expect(await waitUntil { await blocker.hasStarted })
        await timedSend.value
        #expect(await blocker.hasExited)
        #expect(transportEntries.value == 1)

        await #expect(throws: LoomError.self) {
            try await stream.send(
                Data([2]),
                hardDeadline: ContinuousClock.now + .seconds(1)
            )
        }
        #expect(transportEntries.value == 1)
    }

#if canImport(Network)
    @Test("Native send cancellation resolves once and ignores late completion")
    func nativeSendOperationIgnoresLateCompletion() async throws {
        let operation = LoomNetworkFrameworkSendOperation()
        let completion = HardDeadlineSendCompletion()
        let waiter = Task {
            do {
                try await operation.wait { callback in
                    completion.install(callback)
                }
                return false
            } catch {
                return true
            }
        }
        #expect(await waitUntil { completion.isInstalled })

        let cancellation = LoomNetworkError(code: .cancelled, detail: "cancelled")
        #expect(operation.resolve(.failure(cancellation)))
        #expect(await waiter.value)
        completion.complete(nil)
        #expect(!operation.resolve(.success(())))
    }
#endif

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }
}

private actor HardDeadlineBlocker {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    private(set) var hasExited = false

    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func markOperationExited() {
        hasExited = true
    }
}

private final class HardDeadlineCounter: @unchecked Sendable {
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

#if canImport(Network)
private final class HardDeadlineSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Error?) -> Void)?

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func install(_ callback: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func complete(_ error: Error?) {
        lock.lock()
        let callback = callback
        lock.unlock()
        callback?(error)
    }
}
#endif
