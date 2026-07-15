//
//  LoomNetworkFrameworkDatagramReceivePump.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/14/26.
//

#if canImport(Network)
import Foundation

package enum LoomNetworkFrameworkDatagramReceiveEvent: Sendable {
    case datagram(Data)
    case closed
    case failed(LoomNetworkError)
}

package protocol LoomNetworkFrameworkDatagramReceiveDriver: Sendable {
    func receiveMessage(
        completion: @escaping @Sendable (LoomNetworkFrameworkDatagramReceiveEvent) -> Void
    )
}

/// Continuously arms Network.framework UDP receives while exposing one bounded FIFO consumer.
///
/// Network callbacks enqueue under the same lock that owns the pending consumer, then install the
/// next callback before either publishing the queued datagram or resuming the consumer. This keeps
/// ingress armed across executor hops without creating a task per packet.
package final class LoomNetworkFrameworkDatagramReceivePump: @unchecked Sendable {
    private struct QueuedDatagram {
        let data: Data
        let callbackAt: TimeInterval
    }

    private struct ReceiveWaiter {
        let id: UUID
        let continuation: CheckedContinuation<QueuedDatagram?, any Error>
    }

    private enum TerminalState {
        case closed
        case failed(LoomNetworkError)
        case cancelled(LoomNetworkError)
    }

    private let driver: any LoomNetworkFrameworkDatagramReceiveDriver
    private let diagnostics: LoomNetworkFrameworkDatagramReceiveDiagnostics
    private let strategy: LoomNetworkFrameworkDatagramReceiveStrategy
    private let maximumQueuedBytes: Int
    private let maximumQueuedCount: Int
    private let lock = NSLock()

    private var started = false
    private var receiveArmed = false
    private var callbackGeneration: UInt64 = 0
    private var queuedDatagrams: [QueuedDatagram] = []
    private var queuedDatagramHeadIndex = 0
    private var queuedDatagramBytes = 0
    private var receiveWaiter: ReceiveWaiter?
    private var terminalState: TerminalState?

    package init(
        driver: any LoomNetworkFrameworkDatagramReceiveDriver,
        diagnostics: LoomNetworkFrameworkDatagramReceiveDiagnostics = LoomNetworkFrameworkDatagramReceiveDiagnostics(),
        strategy: LoomNetworkFrameworkDatagramReceiveStrategy = .direct,
        maximumQueuedBytes: Int = 32 * 1_024 * 1_024,
        maximumQueuedCount: Int = 8_192
    ) {
        self.driver = driver
        self.diagnostics = diagnostics
        self.strategy = strategy
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        self.maximumQueuedCount = max(1, maximumQueuedCount)
    }

    package func start() {
        lock.lock()
        guard !started, terminalState == nil else {
            lock.unlock()
            return
        }
        started = true
        callbackGeneration &+= 1
        armNextReceiveLocked(generation: callbackGeneration)
        lock.unlock()
    }

    package func receive(maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0 else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "Receive limit must be positive.")
        }
        try Task.checkCancellation()

        let waiterID = UUID()
        let queuedDatagram = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<QueuedDatagram?, any Error>) in
                registerReceive(waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            self.cancelReceive(waiterID: waiterID)
        }

        guard let queuedDatagram else { return nil }
        diagnostics.recordConsumerResume(
            afterCallbackAt: queuedDatagram.callbackAt,
            strategy: strategy
        )
        guard queuedDatagram.data.count <= maximumBytes else {
            throw LoomNetworkError(
                code: .other,
                detail: "Received datagram exceeds the caller's bounded receive size (\(queuedDatagram.data.count) bytes)."
            )
        }
        return queuedDatagram.data
    }

    /// Records a connection failure while preserving datagrams already accepted in FIFO order.
    package func finish(with error: LoomNetworkError) {
        finish(terminalState: .failed(error))
    }

    /// Cancels the pump and discards buffered input because the connection was explicitly cancelled.
    package func cancel(with error: LoomNetworkError) {
        let waiter: ReceiveWaiter?
        lock.lock()
        if case .cancelled? = terminalState {
            lock.unlock()
            return
        }
        terminalState = .cancelled(error)
        callbackGeneration &+= 1
        receiveArmed = false
        queuedDatagrams.removeAll(keepingCapacity: false)
        queuedDatagramHeadIndex = 0
        queuedDatagramBytes = 0
        waiter = receiveWaiter
        receiveWaiter = nil
        lock.unlock()

        waiter.map { resume($0.continuation, for: .cancelled(error)) }
    }

    private func registerReceive(
        waiterID: UUID,
        continuation: CheckedContinuation<QueuedDatagram?, any Error>
    ) {
        let queuedDatagram: QueuedDatagram?
        let terminalState: TerminalState?
        let registrationError: (any Error)?

        lock.lock()
        if Task.isCancelled {
            queuedDatagram = nil
            terminalState = nil
            registrationError = CancellationError()
        } else if let nextDatagram = popQueuedDatagramLocked() {
            queuedDatagram = nextDatagram
            terminalState = nil
            registrationError = nil
        } else if let existingTerminalState = self.terminalState {
            queuedDatagram = nil
            terminalState = existingTerminalState
            registrationError = nil
        } else if receiveWaiter != nil {
            queuedDatagram = nil
            terminalState = nil
            registrationError = LoomNetworkError(
                code: .invalidConfiguration,
                detail: "Concurrent receives on one Loom network connection are not supported."
            )
        } else {
            receiveWaiter = ReceiveWaiter(id: waiterID, continuation: continuation)
            lock.unlock()
            return
        }
        lock.unlock()

        if let registrationError {
            continuation.resume(throwing: registrationError)
        } else if let queuedDatagram {
            continuation.resume(returning: queuedDatagram)
        } else if let terminalState {
            resume(continuation, for: terminalState)
        }
    }

    private func cancelReceive(waiterID: UUID) {
        let continuation: CheckedContinuation<QueuedDatagram?, any Error>?
        lock.lock()
        if receiveWaiter?.id == waiterID {
            continuation = receiveWaiter?.continuation
            receiveWaiter = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func handleReceive(
        _ event: LoomNetworkFrameworkDatagramReceiveEvent,
        generation: UInt64
    ) {
        var deliveredDatagram: QueuedDatagram?
        var resumedWaiter: ReceiveWaiter?
        var completedTerminalState: TerminalState?

        lock.lock()
        guard started,
              terminalState == nil,
              receiveArmed,
              callbackGeneration == generation else {
            lock.unlock()
            return
        }
        receiveArmed = false
        let callbackAt = ProcessInfo.processInfo.systemUptime
        diagnostics.recordCallback(at: callbackAt)

        switch event {
        case let .datagram(data):
            let queuedDatagram = QueuedDatagram(data: data, callbackAt: callbackAt)
            if let receiveWaiter {
                self.receiveWaiter = nil
                resumedWaiter = receiveWaiter
                deliveredDatagram = queuedDatagram
            } else if canEnqueueLocked(data) {
                queuedDatagrams.append(queuedDatagram)
                queuedDatagramBytes += data.count
            } else {
                let error = LoomNetworkError(
                    code: .other,
                    detail: "Network.framework UDP receive buffering exceeded its bounded capacity."
                )
                terminalState = .failed(error)
                completedTerminalState = terminalState
                callbackGeneration &+= 1
            }

            if terminalState == nil {
                armNextReceiveLocked(generation: generation)
            }
        case .closed:
            terminalState = .closed
            completedTerminalState = terminalState
            callbackGeneration &+= 1
            if queuedDatagramCountLocked == 0, let receiveWaiter {
                self.receiveWaiter = nil
                resumedWaiter = receiveWaiter
            }
        case let .failed(error):
            terminalState = .failed(error)
            completedTerminalState = terminalState
            callbackGeneration &+= 1
            if queuedDatagramCountLocked == 0, let receiveWaiter {
                self.receiveWaiter = nil
                resumedWaiter = receiveWaiter
            }
        }
        lock.unlock()

        if let resumedWaiter {
            if let deliveredDatagram {
                resumedWaiter.continuation.resume(returning: deliveredDatagram)
            } else if let completedTerminalState {
                resume(resumedWaiter.continuation, for: completedTerminalState)
            }
        }
    }

    private func armNextReceiveLocked(generation: UInt64) {
        guard started,
              terminalState == nil,
              !receiveArmed,
              callbackGeneration == generation else {
            return
        }
        receiveArmed = true
        diagnostics.recordRegistration()
        driver.receiveMessage { [weak self] event in
            self?.handleReceive(event, generation: generation)
        }
    }

    private func finish(terminalState: TerminalState) {
        let waiter: ReceiveWaiter?
        lock.lock()
        guard self.terminalState == nil else {
            lock.unlock()
            return
        }
        self.terminalState = terminalState
        callbackGeneration &+= 1
        receiveArmed = false
        if queuedDatagramCountLocked == 0 {
            waiter = receiveWaiter
            receiveWaiter = nil
        } else {
            waiter = nil
        }
        lock.unlock()

        if let waiter {
            resume(waiter.continuation, for: terminalState)
        }
    }

    private var queuedDatagramCountLocked: Int {
        queuedDatagrams.count - queuedDatagramHeadIndex
    }

    private func canEnqueueLocked(_ data: Data) -> Bool {
        data.count <= maximumQueuedBytes - queuedDatagramBytes &&
            queuedDatagramCountLocked < maximumQueuedCount
    }

    private func popQueuedDatagramLocked() -> QueuedDatagram? {
        guard queuedDatagramHeadIndex < queuedDatagrams.count else { return nil }
        let queuedDatagram = queuedDatagrams[queuedDatagramHeadIndex]
        queuedDatagramHeadIndex += 1
        queuedDatagramBytes -= queuedDatagram.data.count

        if queuedDatagramHeadIndex >= 1_024,
           queuedDatagramHeadIndex * 2 >= queuedDatagrams.count {
            queuedDatagrams.removeFirst(queuedDatagramHeadIndex)
            queuedDatagramHeadIndex = 0
        } else if queuedDatagramHeadIndex == queuedDatagrams.count {
            queuedDatagrams.removeAll(keepingCapacity: true)
            queuedDatagramHeadIndex = 0
        }
        return queuedDatagram
    }

    private func resume(
        _ continuation: CheckedContinuation<QueuedDatagram?, any Error>,
        for terminalState: TerminalState
    ) {
        switch terminalState {
        case .closed:
            continuation.resume(returning: nil)
        case let .failed(error), let .cancelled(error):
            continuation.resume(throwing: error)
        }
    }
}

#endif
