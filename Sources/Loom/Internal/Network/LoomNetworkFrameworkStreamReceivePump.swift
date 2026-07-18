//
//  LoomNetworkFrameworkStreamReceivePump.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/17/26.
//

#if canImport(Network)
import Foundation

package enum LoomNetworkFrameworkStreamReceiveEvent: Sendable {
    case chunk(Data, endOfStream: Bool)
    case closed
    case failed(LoomNetworkError)
}

package protocol LoomNetworkFrameworkStreamReceiveDriver: Sendable {
    func receiveStreamChunk(
        maximumBytes: Int,
        completion: @escaping @Sendable (LoomNetworkFrameworkStreamReceiveEvent) -> Void
    )
}

/// Keeps one Network.framework stream receive armed while exposing bounded FIFO reads.
///
/// Network callbacks enqueue under the same lock that owns the pending consumer, then install the
/// next callback before resuming that consumer. The queue stops rearming at its byte or chunk bound
/// and resumes as soon as the consumer creates enough capacity for another bounded receive.
package final class LoomNetworkFrameworkStreamReceivePump: @unchecked Sendable {
    private struct ReceiveWaiter {
        let id: UUID
        let maximumBytes: Int
        let continuation: CheckedContinuation<Data?, any Error>
    }

    private enum TerminalState {
        case closed
        case failed(LoomNetworkError)
        case cancelled(LoomNetworkError)
    }

    private let driver: any LoomNetworkFrameworkStreamReceiveDriver
    private let maximumReceiveBytes: Int
    private let maximumQueuedBytes: Int
    private let maximumQueuedChunkCount: Int
    private let lock = NSLock()

    private var started = false
    private var receiveArmed = false
    private var callbackGeneration: UInt64 = 0
    private var queuedChunks: [Data] = []
    private var queuedChunkHeadIndex = 0
    private var queuedChunkHeadOffset = 0
    private var queuedChunkBytes = 0
    private var receiveWaiter: ReceiveWaiter?
    private var terminalState: TerminalState?

    package init(
        driver: any LoomNetworkFrameworkStreamReceiveDriver,
        maximumReceiveBytes: Int = 256 * 1_024,
        maximumQueuedBytes: Int = 8 * 1_024 * 1_024,
        maximumQueuedChunkCount: Int = 256
    ) {
        let boundedQueuedBytes = max(1, maximumQueuedBytes)
        self.driver = driver
        self.maximumReceiveBytes = min(max(1, maximumReceiveBytes), boundedQueuedBytes)
        self.maximumQueuedBytes = boundedQueuedBytes
        self.maximumQueuedChunkCount = max(1, maximumQueuedChunkCount)
    }

    package func start() {
        lock.lock()
        guard !started, terminalState == nil else {
            lock.unlock()
            return
        }
        started = true
        callbackGeneration &+= 1
        armNextReceiveIfCapacityLocked()
        lock.unlock()
    }

    package func receive(maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0 else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "Receive limit must be positive.")
        }
        try Task.checkCancellation()

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data?, any Error>) in
                registerReceive(
                    waiterID: waiterID,
                    maximumBytes: maximumBytes,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancelReceive(waiterID: waiterID)
        }
    }

    /// Records a connection failure while preserving stream bytes already accepted in FIFO order.
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
        discardQueuedChunksLocked()
        waiter = receiveWaiter
        receiveWaiter = nil
        lock.unlock()

        waiter?.continuation.resume(throwing: error)
    }

    private func registerReceive(
        waiterID: UUID,
        maximumBytes: Int,
        continuation: CheckedContinuation<Data?, any Error>
    ) {
        let data: Data?
        let terminalState: TerminalState?
        let registrationError: (any Error)?
        let shouldReturnData: Bool

        lock.lock()
        if Task.isCancelled {
            data = nil
            terminalState = nil
            registrationError = CancellationError()
            shouldReturnData = false
        } else if queuedChunkBytes > 0 {
            data = popQueuedBytesLocked(maximumBytes: maximumBytes)
            terminalState = nil
            registrationError = nil
            shouldReturnData = true
            armNextReceiveIfCapacityLocked()
        } else if let existingTerminalState = self.terminalState {
            data = nil
            terminalState = existingTerminalState
            registrationError = nil
            shouldReturnData = false
        } else if receiveWaiter != nil {
            data = nil
            terminalState = nil
            registrationError = LoomNetworkError(
                code: .invalidConfiguration,
                detail: "Concurrent receives on one Loom network connection are not supported."
            )
            shouldReturnData = false
        } else {
            receiveWaiter = ReceiveWaiter(
                id: waiterID,
                maximumBytes: maximumBytes,
                continuation: continuation
            )
            armNextReceiveIfCapacityLocked()
            lock.unlock()
            return
        }
        lock.unlock()

        if let registrationError {
            continuation.resume(throwing: registrationError)
        } else if shouldReturnData {
            continuation.resume(returning: data)
        } else if let terminalState {
            resume(continuation, for: terminalState)
        }
    }

    private func cancelReceive(waiterID: UUID) {
        let continuation: CheckedContinuation<Data?, any Error>?
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
        _ event: LoomNetworkFrameworkStreamReceiveEvent,
        generation: UInt64
    ) {
        var deliveredData: Data?
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

        switch event {
        case let .chunk(data, endOfStream):
            guard !data.isEmpty,
                  data.count <= maximumReceiveBytes,
                  canEnqueueLocked(data) else {
                let error = LoomNetworkError(
                    code: .other,
                    detail: "Network.framework stream receive exceeded its bounded capacity."
                )
                terminalState = .failed(error)
                completedTerminalState = terminalState
                callbackGeneration &+= 1
                if queuedChunkBytes == 0, let receiveWaiter {
                    self.receiveWaiter = nil
                    resumedWaiter = receiveWaiter
                }
                break
            }

            queuedChunks.append(data)
            queuedChunkBytes += data.count

            if let receiveWaiter {
                self.receiveWaiter = nil
                resumedWaiter = receiveWaiter
                deliveredData = popQueuedBytesLocked(maximumBytes: receiveWaiter.maximumBytes)
            }

            if endOfStream {
                terminalState = .closed
                completedTerminalState = terminalState
                callbackGeneration &+= 1
            } else {
                armNextReceiveIfCapacityLocked()
            }
        case .closed:
            terminalState = .closed
            completedTerminalState = terminalState
            callbackGeneration &+= 1
            if queuedChunkBytes == 0, let receiveWaiter {
                self.receiveWaiter = nil
                resumedWaiter = receiveWaiter
            }
        case let .failed(error):
            terminalState = .failed(error)
            completedTerminalState = terminalState
            callbackGeneration &+= 1
            if queuedChunkBytes == 0, let receiveWaiter {
                self.receiveWaiter = nil
                resumedWaiter = receiveWaiter
            }
        }
        lock.unlock()

        if let resumedWaiter {
            if let deliveredData {
                resumedWaiter.continuation.resume(returning: deliveredData)
            } else if let completedTerminalState {
                resume(resumedWaiter.continuation, for: completedTerminalState)
            }
        }
    }

    private func armNextReceiveIfCapacityLocked() {
        guard started,
              terminalState == nil,
              !receiveArmed,
              queuedChunkCountLocked < maximumQueuedChunkCount,
              queuedChunkBytes <= maximumQueuedBytes - maximumReceiveBytes else {
            return
        }
        receiveArmed = true
        let generation = callbackGeneration
        driver.receiveStreamChunk(maximumBytes: maximumReceiveBytes) { [weak self] event in
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
        if queuedChunkBytes == 0 {
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

    private var queuedChunkCountLocked: Int {
        queuedChunks.count - queuedChunkHeadIndex
    }

    private func canEnqueueLocked(_ data: Data) -> Bool {
        data.count <= maximumQueuedBytes - queuedChunkBytes &&
            queuedChunkCountLocked < maximumQueuedChunkCount
    }

    private func popQueuedBytesLocked(maximumBytes: Int) -> Data {
        let chunk = queuedChunks[queuedChunkHeadIndex]
        let availableBytes = chunk.count - queuedChunkHeadOffset
        let consumedBytes = min(maximumBytes, availableBytes)
        let data: Data

        if queuedChunkHeadOffset == 0, consumedBytes == chunk.count {
            data = chunk
        } else {
            let start = chunk.index(chunk.startIndex, offsetBy: queuedChunkHeadOffset)
            let end = chunk.index(start, offsetBy: consumedBytes)
            data = Data(chunk[start ..< end])
        }

        queuedChunkBytes -= consumedBytes
        if consumedBytes == availableBytes {
            queuedChunkHeadIndex += 1
            queuedChunkHeadOffset = 0
            compactQueuedChunksIfNeededLocked()
        } else {
            queuedChunkHeadOffset += consumedBytes
        }
        return data
    }

    private func compactQueuedChunksIfNeededLocked() {
        if queuedChunkHeadIndex >= 1_024,
           queuedChunkHeadIndex * 2 >= queuedChunks.count {
            queuedChunks.removeFirst(queuedChunkHeadIndex)
            queuedChunkHeadIndex = 0
        } else if queuedChunkHeadIndex == queuedChunks.count {
            queuedChunks.removeAll(keepingCapacity: true)
            queuedChunkHeadIndex = 0
        }
    }

    private func discardQueuedChunksLocked() {
        queuedChunks.removeAll(keepingCapacity: false)
        queuedChunkHeadIndex = 0
        queuedChunkHeadOffset = 0
        queuedChunkBytes = 0
    }

    private func resume(
        _ continuation: CheckedContinuation<Data?, any Error>,
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
