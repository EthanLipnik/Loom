//
//  LoomAsyncTimeout.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

private final class LoomAsyncTimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isResolved = false

    init(continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func install(tasks: [Task<Void, Never>]) {
        lock.lock()
        if isResolved {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }

    @discardableResult
    func resolve(
        _ result: Result<Value, any Error>,
        onWinningResolution: @Sendable () -> Void = {}
    ) -> Bool {
        lock.lock()
        guard !isResolved, let continuation else {
            lock.unlock()
            return false
        }
        isResolved = true
        self.continuation = nil
        let tasks = self.tasks
        self.tasks.removeAll(keepingCapacity: false)
        lock.unlock()

        tasks.forEach { $0.cancel() }
        onWinningResolution()
        continuation.resume(with: result)
        return true
    }
}

private final class LoomAsyncTimeoutCancellationRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: LoomAsyncTimeoutGate<Value>?
    private var isCancelled = false

    func install(_ gate: LoomAsyncTimeoutGate<Value>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            gate.resolve(.failure(CancellationError()))
            return
        }
        self.gate = gate
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let gate = gate
        lock.unlock()
        gate?.resolve(.failure(CancellationError()))
    }
}

/// Races an asynchronous operation against a monotonic deadline without waiting for a
/// cancellation-insensitive operation before returning the timeout to its caller.
package func withLoomThrowingDeadline<Value: Sendable>(
    _ deadline: ContinuousClock.Instant,
    onTimeout: @escaping @Sendable () -> Void = {},
    timeoutError: @escaping @Sendable () -> any Error = { LoomError.timeout },
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let cancellationRelay = LoomAsyncTimeoutCancellationRelay<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let gate = LoomAsyncTimeoutGate(continuation: continuation)
            cancellationRelay.install(gate)
            let operationTask = Task {
                do {
                    gate.resolve(.success(try await operation()))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                gate.resolve(
                    .failure(timeoutError()),
                    onWinningResolution: onTimeout
                )
            }
            gate.install(tasks: [operationTask, timeoutTask])
        }
    } onCancel: {
        cancellationRelay.cancel()
    }
}

/// Bounds cancellation-insensitive asynchronous work independently from the caller waiting
/// for its deadline. A timed-out operation retains its slot until its task actually exits.
package actor LoomOutstandingOperationLimiter {
    private var maximumConcurrentOperations: Int
    private var activeOperationCount = 0

    package init(maximumConcurrentOperations: Int) {
        self.maximumConcurrentOperations = max(1, maximumConcurrentOperations)
    }

    package func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard activeOperationCount < maximumConcurrentOperations else {
            throw LoomError.protocolError("Loom asynchronous operation admission limit reached.")
        }
        activeOperationCount += 1
        defer {
            activeOperationCount = max(0, activeOperationCount - 1)
        }
        return try await operation()
    }

    package var activeCount: Int {
        activeOperationCount
    }

    package func updateLimit(_ maximumConcurrentOperations: Int) {
        self.maximumConcurrentOperations = max(1, maximumConcurrentOperations)
    }
}

/// Races an asynchronous operation against a relative monotonic timeout.
package func withLoomThrowingTimeout<Value: Sendable>(
    _ timeout: Duration,
    onTimeout: @escaping @Sendable () -> Void = {},
    timeoutError: @escaping @Sendable () -> any Error = { LoomError.timeout },
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withLoomThrowingDeadline(
        ContinuousClock.now + max(.milliseconds(1), timeout),
        onTimeout: onTimeout,
        timeoutError: timeoutError,
        operation: operation
    )
}
