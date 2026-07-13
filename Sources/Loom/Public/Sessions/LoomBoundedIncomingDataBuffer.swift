//
//  LoomBoundedIncomingDataBuffer.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Demand-driven byte-bounded storage backing a multiplexed stream's public `AsyncStream`.
final class LoomBoundedIncomingDataBuffer: @unchecked Sendable {
    enum YieldResult {
        case accepted
        case invalid
        case overflow
        case terminated
    }

    struct ReplacingYieldResult {
        let result: YieldResult
        let replacedPayloadCount: Int
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
    private var isFinished = false

    init(
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

    func makeStream() -> AsyncStream<Data> {
        AsyncStream(
            unfolding: { [weak self] in
                guard let self else { return nil }
                return await self.next()
            },
            onCancel: { [weak self] in
                self?.abort()
            }
        )
    }

    /// Delivers directly to a suspended consumer or retains the payload within the byte budget.
    func yield(
        _ data: Data,
        alreadyRetained: Bool = false
    ) -> YieldResult {
        let waiter: CheckedContinuation<Data?, Never>?

        lock.lock()
        guard !isFinished else {
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
                  alreadyRetained || retainedCapacityBudget.reserve(
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

        if waiter != nil, alreadyRetained {
            retainedCapacityBudget.release(
                bytes: data.count,
                payloadCount: 1,
                batchCount: 1
            )
        }
        waiter?.resume(returning: data)
        return .accepted
    }

    /// Delivers directly to a suspended consumer or replaces the oldest buffered
    /// payloads until the newest payload fits. Intended for explicitly lossy lanes.
    func yieldReplacingOldest(_ data: Data) -> ReplacingYieldResult {
        let waiter: CheckedContinuation<Data?, Never>?
        var replacedPayloadCount = 0

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return ReplacingYieldResult(result: .terminated, replacedPayloadCount: 0)
        }
        guard !data.isEmpty else {
            lock.unlock()
            return ReplacingYieldResult(result: .invalid, replacedPayloadCount: 0)
        }
        guard data.count <= maximumBufferedBytes else {
            lock.unlock()
            return ReplacingYieldResult(result: .overflow, replacedPayloadCount: 0)
        }
        if let waiterEntry = waiters.first {
            waiters.removeValue(forKey: waiterEntry.key)
            waiterEntry.value.waiter.isCompleted = true
            waiter = waiterEntry.value.continuation
        } else {
            var replacedBytes = 0
            while bufferedPayloadIndex < bufferedPayloads.count,
                  data.count > maximumBufferedBytes - bufferedBytes ||
                  bufferedPayloads.count - bufferedPayloadIndex >= maximumBufferedItems {
                let replacedPayload = bufferedPayloads[bufferedPayloadIndex]
                bufferedPayloadIndex += 1
                bufferedBytes -= replacedPayload.count
                replacedBytes += replacedPayload.count
                replacedPayloadCount += 1
            }
            compactBufferedPayloadsIfNeededLocked()
            if replacedPayloadCount > 0 {
                retainedCapacityBudget.release(
                    bytes: replacedBytes,
                    payloadCount: replacedPayloadCount,
                    batchCount: replacedPayloadCount
                )
            }
            guard retainedCapacityBudget.reserve(
                bytes: data.count,
                payloadCount: 1,
                startsNewBatch: true
            ) else {
                lock.unlock()
                return ReplacingYieldResult(
                    result: .overflow,
                    replacedPayloadCount: replacedPayloadCount
                )
            }
            bufferedPayloads.append(data)
            bufferedBytes += data.count
            waiter = nil
        }
        lock.unlock()

        waiter?.resume(returning: data)
        return ReplacingYieldResult(
            result: .accepted,
            replacedPayloadCount: replacedPayloadCount
        )
    }

    func finish() {
        finish(droppingBufferedPayloads: false)
    }

    func abort() {
        finish(droppingBufferedPayloads: true)
    }

    private func finish(droppingBufferedPayloads: Bool) {
        let pendingWaiters: [PendingWaiter]
        let droppedBytes: Int
        let droppedPayloadCount: Int

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        if droppingBufferedPayloads {
            droppedBytes = bufferedBytes
            droppedPayloadCount = bufferedPayloads.count - bufferedPayloadIndex
            bufferedPayloads.removeAll(keepingCapacity: false)
            bufferedPayloadIndex = 0
            bufferedBytes = 0
        } else {
            droppedBytes = 0
            droppedPayloadCount = 0
        }
        pendingWaiters = Array(waiters.values)
        for pendingWaiter in pendingWaiters {
            pendingWaiter.waiter.isCompleted = true
        }
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

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

    private func next() async -> Data? {
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result: Data??

                lock.lock()
                if waiter.isCancelled || Task.isCancelled {
                    waiter.isCompleted = true
                    result = .some(nil)
                } else if bufferedPayloadIndex < bufferedPayloads.count {
                    let payload = bufferedPayloads[bufferedPayloadIndex]
                    bufferedPayloadIndex += 1
                    bufferedBytes -= payload.count
                    compactBufferedPayloadsIfNeededLocked()
                    waiter.isCompleted = true
                    result = .some(payload)
                    retainedCapacityBudget.release(
                        bytes: payload.count,
                        payloadCount: 1,
                        batchCount: 1
                    )
                } else if isFinished {
                    waiter.isCompleted = true
                    result = .some(nil)
                } else {
                    waiters[waiter.id] = PendingWaiter(
                        waiter: waiter,
                        continuation: continuation
                    )
                    result = nil
                }
                lock.unlock()

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
        if waiter.isCompleted || isFinished {
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
            bufferedPayloads.removeAll(keepingCapacity: true)
            bufferedPayloadIndex = 0
        } else if bufferedPayloadIndex >= 64,
                  bufferedPayloadIndex * 2 >= bufferedPayloads.count {
            bufferedPayloads.removeFirst(bufferedPayloadIndex)
            bufferedPayloadIndex = 0
        }
    }
}
