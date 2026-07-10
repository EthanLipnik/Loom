//
//  LoomPriorityIncomingPayloadBuffer.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Byte- and item-bounded storage for the direct priority-input receive lane.
///
/// Overflow aborts the stream instead of dropping an ordered/protected payload and
/// continuing with a gap that the caller cannot distinguish from successful delivery.
package final class LoomPriorityIncomingPayloadBuffer: @unchecked Sendable {
    package enum YieldResult: Equatable, Sendable {
        case accepted
        case invalid
        case overflow
        case terminated
    }

    private final class Waiter: @unchecked Sendable {
        let id = UUID()
        var isCancelled = false
        var isCompleted = false
    }

    private struct PendingWaiter {
        let waiter: Waiter
        let continuation: CheckedContinuation<Data?, Never>
    }

    private let lock = NSLock()
    private let maximumBufferedBytes: Int
    private let maximumBufferedItems: Int
    private let retainedCapacityBudget: LoomIncomingRetainedCapacityBudget
    private var bufferedPayloads: [Data] = []
    private var bufferedPayloadIndex = 0
    private var bufferedBytes = 0
    private var waiters: [UUID: PendingWaiter] = [:]
    private var producer: Task<Void, Never>?
    private var isAcceptingPayloads = true
    private var isAborted = false

    package init(
        maximumBufferedBytes: Int,
        maximumBufferedItems: Int,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil
    ) {
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.maximumBufferedItems = max(1, maximumBufferedItems)
        self.retainedCapacityBudget = retainedCapacityBudget ?? LoomIncomingRetainedCapacityBudget(
            maximumBytes: self.maximumBufferedBytes,
            maximumPayloadCount: self.maximumBufferedItems,
            maximumBatchCount: self.maximumBufferedItems
        )
    }

    deinit {
        producer?.cancel()
        releaseBufferedReservations()
        for pendingWaiter in waiters.values {
            pendingWaiter.continuation.resume(returning: nil)
        }
    }

    package func makeStream() -> AsyncStream<Data> {
        AsyncStream(
            unfolding: { [self] in
                return await self.next()
            },
            onCancel: { [self] in
                abort()
            }
        )
    }

    package func installProducer(_ task: Task<Void, Never>) {
        lock.lock()
        if isAcceptingPayloads {
            producer = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    package func yield(_ data: Data) -> YieldResult {
        let waiter: CheckedContinuation<Data?, Never>?

        lock.lock()
        guard isAcceptingPayloads else {
            lock.unlock()
            return .terminated
        }
        guard !data.isEmpty else {
            lock.unlock()
            return .invalid
        }
        guard data.count <= maximumBufferedBytes else {
            lock.unlock()
            return .overflow
        }
        if let waiterEntry = waiters.first {
            waiters.removeValue(forKey: waiterEntry.key)
            waiterEntry.value.waiter.isCompleted = true
            waiter = waiterEntry.value.continuation
        } else {
            guard data.count <= maximumBufferedBytes - bufferedBytes,
                  bufferedPayloads.count - bufferedPayloadIndex < maximumBufferedItems,
                  retainedCapacityBudget.reserve(
                      bytes: data.count,
                      payloadCount: 1,
                      startsNewBatch: true
                  ) else {
                lock.unlock()
                return .overflow
            }
            bufferedPayloads.append(data)
            bufferedBytes += data.count
            waiter = nil
        }
        lock.unlock()

        waiter?.resume(returning: data)
        return .accepted
    }

    /// Stops accepting payloads while allowing already accepted payloads to drain in order.
    package func finish() {
        let pendingWaiters: [PendingWaiter]

        lock.lock()
        guard isAcceptingPayloads else {
            producer = nil
            lock.unlock()
            return
        }
        isAcceptingPayloads = false
        producer = nil
        if bufferedPayloadIndex == bufferedPayloads.count {
            pendingWaiters = Array(waiters.values)
            for pendingWaiter in pendingWaiters {
                pendingWaiter.waiter.isCompleted = true
            }
            waiters.removeAll(keepingCapacity: false)
        } else {
            pendingWaiters = []
        }
        lock.unlock()

        for pendingWaiter in pendingWaiters {
            pendingWaiter.continuation.resume(returning: nil)
        }
    }

    /// Fails closed on overflow or consumer termination and releases every reservation.
    package func abort() {
        let pendingWaiters: [PendingWaiter]
        let producer: Task<Void, Never>?
        let droppedBytes: Int
        let droppedPayloadCount: Int

        lock.lock()
        guard !isAborted else {
            lock.unlock()
            return
        }
        isAcceptingPayloads = false
        isAborted = true
        producer = self.producer
        self.producer = nil
        droppedBytes = bufferedBytes
        droppedPayloadCount = bufferedPayloads.count - bufferedPayloadIndex
        bufferedPayloads.removeAll(keepingCapacity: false)
        bufferedPayloadIndex = 0
        bufferedBytes = 0
        pendingWaiters = Array(waiters.values)
        for pendingWaiter in pendingWaiters {
            pendingWaiter.waiter.isCompleted = true
        }
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        producer?.cancel()
        if droppedPayloadCount > 0 {
            retainedCapacityBudget.release(
                bytes: droppedBytes,
                payloadCount: droppedPayloadCount,
                batchCount: droppedPayloadCount
            )
        }
        for pendingWaiter in pendingWaiters {
            pendingWaiter.continuation.resume(returning: nil)
        }
    }

    package var bufferedBytesForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferedBytes
    }

    private func next() async -> Data? {
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result: Data??
                let releasedPayload: Data?

                lock.lock()
                if waiter.isCancelled || Task.isCancelled {
                    waiter.isCompleted = true
                    result = .some(nil)
                    releasedPayload = nil
                } else if bufferedPayloadIndex < bufferedPayloads.count {
                    let payload = bufferedPayloads[bufferedPayloadIndex]
                    bufferedPayloadIndex += 1
                    bufferedBytes -= payload.count
                    compactBufferedPayloadsIfNeededLocked()
                    waiter.isCompleted = true
                    result = .some(payload)
                    releasedPayload = payload
                } else if !isAcceptingPayloads {
                    waiter.isCompleted = true
                    result = .some(nil)
                    releasedPayload = nil
                } else {
                    waiters[waiter.id] = PendingWaiter(
                        waiter: waiter,
                        continuation: continuation
                    )
                    result = nil
                    releasedPayload = nil
                }
                lock.unlock()

                if let releasedPayload {
                    retainedCapacityBudget.release(
                        bytes: releasedPayload.count,
                        payloadCount: 1,
                        batchCount: 1
                    )
                }
                if let result {
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { [weak self] in
            self?.cancel(waiter)
        }
    }

    private func cancel(_ waiter: Waiter) {
        let continuation: CheckedContinuation<Data?, Never>?

        lock.lock()
        if waiter.isCompleted || isAborted {
            continuation = nil
        } else if let registeredWaiter = waiters.removeValue(forKey: waiter.id) {
            registeredWaiter.waiter.isCompleted = true
            continuation = registeredWaiter.continuation
        } else {
            waiter.isCancelled = true
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(returning: nil)
    }

    private func compactBufferedPayloadsIfNeededLocked() {
        guard bufferedPayloadIndex > 0 else { return }
        if bufferedPayloadIndex == bufferedPayloads.count {
            bufferedPayloads.removeAll(keepingCapacity: false)
            bufferedPayloadIndex = 0
        } else if bufferedPayloadIndex >= 64,
                  bufferedPayloadIndex * 2 >= bufferedPayloads.count {
            bufferedPayloads.removeFirst(bufferedPayloadIndex)
            bufferedPayloadIndex = 0
        }
    }

    private func releaseBufferedReservations() {
        let droppedBytes: Int
        let droppedPayloadCount: Int

        lock.lock()
        droppedBytes = bufferedBytes
        droppedPayloadCount = bufferedPayloads.count - bufferedPayloadIndex
        bufferedPayloads.removeAll(keepingCapacity: false)
        bufferedPayloadIndex = 0
        bufferedBytes = 0
        lock.unlock()

        guard droppedPayloadCount > 0 else { return }
        retainedCapacityBudget.release(
            bytes: droppedBytes,
            payloadCount: droppedPayloadCount,
            batchCount: droppedPayloadCount
        )
    }
}
