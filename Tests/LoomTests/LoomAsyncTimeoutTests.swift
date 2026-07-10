//
//  LoomAsyncTimeoutTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Async Timeout")
struct LoomAsyncTimeoutTests {
    @Test("Timeout returns without waiting for cancellation-insensitive work")
    func timeoutReturnsIndependently() async {
        let blocker = CancellationInsensitiveBlocker()
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            try await withLoomThrowingTimeout(.milliseconds(25)) {
                await blocker.wait()
            }
            Issue.record("Expected timeout.")
        } catch LoomError.timeout {
            // Expected.
        } catch {
            Issue.record("Expected LoomError.timeout, got \(error.localizedDescription).")
        }

        #expect(startedAt.duration(to: clock.now) < .milliseconds(500))
        await blocker.release()
    }

    @Test("Timeout side effects run only when the deadline wins")
    func timeoutSideEffectsRequireWinningResolution() async {
        for iteration in 0 ..< 40 {
            let sideEffectCount = TimeoutLockedCounter()
            let didTimeOut: Bool
            do {
                _ = try await withLoomThrowingTimeout(
                    .milliseconds(1),
                    onTimeout: {
                        sideEffectCount.increment()
                    }
                ) {
                    if iteration.isMultiple(of: 2) {
                        return iteration
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                    return iteration
                }
                didTimeOut = false
            } catch LoomError.timeout {
                didTimeOut = true
            } catch {
                Issue.record("Unexpected timeout race error: \(error.localizedDescription).")
                didTimeOut = false
            }

            #expect(sideEffectCount.value == (didTimeOut ? 1 : 0))
        }
    }

    @Test("Timed-out cancellation-insensitive work remains admission bounded")
    func timedOutWorkRetainsAdmissionUntilExit() async throws {
        let limiter = LoomOutstandingOperationLimiter(maximumConcurrentOperations: 1)
        let blocker = CancellationInsensitiveBlocker()
        let timedOperation = Task {
            do {
                try await withLoomThrowingTimeout(.milliseconds(50)) {
                    try await limiter.run {
                        await blocker.wait()
                    }
                }
                return false
            } catch LoomError.timeout {
                return true
            } catch {
                return false
            }
        }

        #expect(await waitUntil { await limiter.activeCount == 1 })
        #expect(await timedOperation.value)
        #expect(await limiter.activeCount == 1)
        await #expect(throws: LoomError.self) {
            try await limiter.run {}
        }

        await blocker.release()
        #expect(await waitUntil { await limiter.activeCount == 0 })
        let value = try await limiter.run { 7 }
        #expect(value == 7)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private final class TimeoutLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private actor CancellationInsensitiveBlocker {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            guard !isReleased else {
                continuation.resume()
                return
            }
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
