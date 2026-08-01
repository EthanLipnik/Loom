//
//  LoomQuiescingHardDeadline.swift
//  Loom
//
//  Created by Ethan Lipnik on 8/1/26.
//

import Foundation

/// Admission shared by reliable send entry points and destructive transport teardown.
/// Closing is synchronous so a deadline winner fences later writes before actor re-entry.
package final class LoomReliableSendAdmission: @unchecked Sendable {
    package enum DeadlineAcquisition: @unchecked Sendable {
        case admitted(Lease)
        case expired
        case closed
    }

    package final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private weak var admission: LoomReliableSendAdmission?
        private let identifier: UInt64
        private var isReleased = false

        fileprivate init(admission: LoomReliableSendAdmission, identifier: UInt64) {
            self.admission = admission
            self.identifier = identifier
        }

        /// Releases one admitted reliable operation. Explicit release keeps quiescence independent
        /// of ARC timing while the idempotent guard makes error-path defers safe.
        package func release() {
            lock.lock()
            guard !isReleased else {
                lock.unlock()
                return
            }
            isReleased = true
            let admission = admission
            self.admission = nil
            lock.unlock()
            admission?.release(identifier: identifier)
        }

        deinit {
            release()
        }
    }

    private let lock = NSLock()
    private var isOpenStorage = true
    private var nextLeaseIdentifier: UInt64 = 1
    private var activeLeaseIdentifiers = Set<UInt64>()
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpenStorage
    }

    /// Atomically admits one reliable operation. The lease must be acquired before nonce allocation
    /// for ordinary sends so a concurrent hard cut cannot leave untracked authenticated work.
    package func acquire() -> Lease? {
        lock.lock()
        guard isOpenStorage else {
            lock.unlock()
            return nil
        }
        let identifier = nextLeaseIdentifier
        nextLeaseIdentifier = identifier == UInt64.max ? 1 : identifier + 1
        guard activeLeaseIdentifiers.insert(identifier).inserted else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return Lease(admission: self, identifier: identifier)
    }

    /// Resolves the deadline and admission fence while holding the same lock. A caller therefore
    /// either owns a tracked lease before allocating an authenticated nonce, or performs no
    /// session-visible work at all.
    package func acquire(before deadline: ContinuousClock.Instant) -> DeadlineAcquisition {
        lock.lock()
        guard isOpenStorage else {
            lock.unlock()
            return .closed
        }
        guard ContinuousClock.now < deadline else {
            lock.unlock()
            return .expired
        }
        let identifier = nextLeaseIdentifier
        nextLeaseIdentifier = identifier == UInt64.max ? 1 : identifier + 1
        guard activeLeaseIdentifiers.insert(identifier).inserted else {
            lock.unlock()
            return .closed
        }
        lock.unlock()
        return .admitted(Lease(admission: self, identifier: identifier))
    }

    package func close() {
        lock.lock()
        isOpenStorage = false
        lock.unlock()
    }

    /// Waits until every operation admitted before the close fence has left its transport call.
    package func waitForQuiescence() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !activeLeaseIdentifiers.isEmpty else {
                lock.unlock()
                continuation.resume()
                return
            }
            quiescenceWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func release(identifier: UInt64) {
        lock.lock()
        guard activeLeaseIdentifiers.remove(identifier) != nil else {
            lock.unlock()
            return
        }
        guard activeLeaseIdentifiers.isEmpty else {
            lock.unlock()
            return
        }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Transfers an already-admitted lease into a deadline operation without relying on task startup
/// ordering. A hard cut can release a lease whose task never began, while a running task retains
/// exclusive responsibility for releasing its own lease after transport teardown.
package final class LoomReliableSendLeaseTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: LoomReliableSendAdmission.Lease?

    package init(_ lease: LoomReliableSendAdmission.Lease) {
        self.lease = lease
    }

    package func takeForOperation() -> LoomReliableSendAdmission.Lease? {
        lock.lock()
        defer { lock.unlock() }
        let lease = lease
        self.lease = nil
        return lease
    }

    package func releaseIfOperationHasNotStarted() {
        lock.lock()
        let lease = lease
        self.lease = nil
        lock.unlock()
        lease?.release()
    }

    deinit {
        releaseIfOperationHasNotStarted()
    }
}

/// A destructive deadline waits for transport teardown and the attempted write to terminate.
/// Ordered reliable bytes cannot be abandoned independently because their partial acceptance is unknowable.
package func withLoomQuiescingHardDeadline(
    _ deadline: ContinuousClock.Instant,
    closeAdmission: @escaping @Sendable () -> Void,
    releaseUnstartedOperation: @escaping @Sendable () -> Void = {},
    quiesce: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    let cancellationRelay = LoomQuiescingHardDeadlineCancellationRelay()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let gate = LoomQuiescingHardDeadlineGate(
                continuation: continuation,
                deadline: deadline,
                closeAdmission: closeAdmission,
                releaseUnstartedOperation: releaseUnstartedOperation,
                quiesce: quiesce,
                operation: operation
            )
            cancellationRelay.install(gate)
            gate.start()
        }
    } onCancel: {
        cancellationRelay.cancel()
    }
}

private final class LoomQuiescingHardDeadlineCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: LoomQuiescingHardDeadlineGate?
    private var isCancelled = false

    func install(_ gate: LoomQuiescingHardDeadlineGate) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            gate.cancel()
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
        gate?.cancel()
    }
}

private final class LoomQuiescingHardDeadlineGate: @unchecked Sendable {
    private enum Phase: Equatable {
        case pendingStart
        case running
        case hardCut
        case resolved
    }

    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private let closeAdmission: @Sendable () -> Void
    private let releaseUnstartedOperation: @Sendable () -> Void
    private let quiesce: @Sendable () async -> Void
    private let operation: @Sendable () async throws -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var phase: Phase = .pendingStart

    init(
        continuation: CheckedContinuation<Void, any Error>,
        deadline: ContinuousClock.Instant,
        closeAdmission: @escaping @Sendable () -> Void,
        releaseUnstartedOperation: @escaping @Sendable () -> Void,
        quiesce: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        self.continuation = continuation
        self.deadline = deadline
        self.closeAdmission = closeAdmission
        self.releaseUnstartedOperation = releaseUnstartedOperation
        self.quiesce = quiesce
        self.operation = operation
    }

    func start() {
        lock.lock()
        guard phase == .pendingStart else {
            lock.unlock()
            return
        }
        guard ContinuousClock.now < deadline else {
            lock.unlock()
            beginHardCut(error: LoomError.timeout)
            return
        }
        phase = .running
        let operationTask = Task { [operation] in
            do {
                try await operation()
                self.operationFinished(.success(()))
            } catch {
                self.operationFinished(.failure(error))
            }
        }
        let deadlineTask = Task { [deadline] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            self.deadlineExpired()
        }
        self.operationTask = operationTask
        self.deadlineTask = deadlineTask
        lock.unlock()
    }

    func cancel() {
        beginHardCut(error: CancellationError())
    }

    private func deadlineExpired() {
        beginHardCut(error: LoomError.timeout)
    }

    private func operationFinished(_ result: Result<Void, any Error>) {
        lock.lock()
        guard phase == .running, let continuation else {
            lock.unlock()
            return
        }
        phase = .resolved
        self.continuation = nil
        let deadlineTask = deadlineTask
        self.deadlineTask = nil
        operationTask = nil
        lock.unlock()

        deadlineTask?.cancel()
        continuation.resume(with: result)
    }

    private func beginHardCut(error: any Error) {
        lock.lock()
        switch phase {
        case .pendingStart:
            phase = .hardCut
            lock.unlock()
            closeAdmission()
            releaseUnstartedOperation()
            Task {
                await quiesce()
                self.finishHardCut(error: error)
            }
            return
        case .running:
            guard let operationTask else {
                lock.unlock()
                return
            }
            phase = .hardCut
            let deadlineTask = deadlineTask
            self.deadlineTask = nil
            lock.unlock()

            // The admission fence must precede asynchronous teardown so actor scheduling cannot admit a later write.
            closeAdmission()
            // A created task is not proof that its body acquired the transferred lease.
            releaseUnstartedOperation()
            operationTask.cancel()
            deadlineTask?.cancel()
            Task {
                await quiesce()
                _ = await operationTask.result
                self.finishHardCut(error: error)
            }
        case .hardCut,
             .resolved:
            lock.unlock()
        }
    }

    private func finishHardCut(error: any Error) {
        lock.lock()
        guard phase == .hardCut, let continuation else {
            lock.unlock()
            return
        }
        phase = .resolved
        self.continuation = nil
        operationTask = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
