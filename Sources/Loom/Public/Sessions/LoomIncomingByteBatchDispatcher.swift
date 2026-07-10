//
//  LoomIncomingByteBatchDispatcher.swift
//  Loom
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation

final class LoomIncomingByteBatchDispatcher: @unchecked Sendable {
    enum YieldResult: Equatable {
        case accepted
        case overflow
        case terminated
    }

    private struct PendingBatch: Sendable {
        let payloads: [Data]
        let byteCount: Int

        var payloadCount: Int {
            payloads.count
        }
    }

    private enum Delivery: @unchecked Sendable {
        case async(@Sendable ([Data]) async -> Void)
        case immediate(@Sendable ([Data]) -> Void)
    }

    private let lock = NSLock()
    private let dispatchLock = NSRecursiveLock()
    private let maxBatchSize: Int
    private let maxDelay: Duration
    private let maximumBufferedBytes: Int
    private let maximumBufferedPayloadCount: Int
    private let maximumBufferedBatchCount: Int
    private let retainedCapacityBudget: LoomIncomingRetainedCapacityBudget
    private let flushesPartialBatchesImmediately: Bool
    private let delivery: Delivery
    private let onOverflow: @Sendable () -> Void
    private var bufferedPayloads: [Data] = []
    private var bufferedPayloadBytes = 0
    /// Includes partial, queued, and currently handled asynchronous batches.
    private var retainedBytes = 0
    private var retainedPayloadCount = 0
    private var retainedBatchCount = 0
    private var pendingAsyncBatches: [PendingBatch] = []
    private var workerTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var isFinished = false
    private var didReportOverflow = false

    init(
        maxBatchSize: Int,
        maxDelay: Duration,
        maximumBufferedBytes: Int = LoomMessageLimits.maxReceiveBufferBytes,
        maximumBufferedPayloadCount: Int = LoomMessageLimits.maxBufferedPayloadsPerStream,
        maximumBufferedBatchCount: Int = LoomMessageLimits.maxBufferedPayloadsPerStream,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        onOverflow: @escaping @Sendable () -> Void = {},
        handler: @escaping @Sendable ([Data]) async -> Void
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.maxDelay = maxDelay
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.maximumBufferedPayloadCount = max(1, maximumBufferedPayloadCount)
        self.maximumBufferedBatchCount = max(1, maximumBufferedBatchCount)
        self.retainedCapacityBudget = retainedCapacityBudget ?? LoomIncomingRetainedCapacityBudget(
            maximumBytes: self.maximumBufferedBytes,
            maximumPayloadCount: self.maximumBufferedPayloadCount,
            maximumBatchCount: self.maximumBufferedBatchCount
        )
        flushesPartialBatchesImmediately = maxDelay == .zero
        delivery = .async(handler)
        self.onOverflow = onOverflow
        bufferedPayloads.reserveCapacity(min(self.maxBatchSize, 256))
    }

    init(
        maxBatchSize: Int,
        maximumBufferedBytes: Int = LoomMessageLimits.maxReceiveBufferBytes,
        maximumBufferedPayloadCount: Int = LoomMessageLimits.maxBufferedPayloadsPerStream,
        maximumBufferedBatchCount: Int = LoomMessageLimits.maxBufferedPayloadsPerStream,
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil,
        onOverflow: @escaping @Sendable () -> Void = {},
        immediateHandler: @escaping @Sendable ([Data]) -> Void
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        maxDelay = .zero
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.maximumBufferedPayloadCount = max(1, maximumBufferedPayloadCount)
        self.maximumBufferedBatchCount = max(1, maximumBufferedBatchCount)
        self.retainedCapacityBudget = retainedCapacityBudget ?? LoomIncomingRetainedCapacityBudget(
            maximumBytes: self.maximumBufferedBytes,
            maximumPayloadCount: self.maximumBufferedPayloadCount,
            maximumBatchCount: self.maximumBufferedBatchCount
        )
        flushesPartialBatchesImmediately = false
        delivery = .immediate(immediateHandler)
        self.onOverflow = onOverflow
        bufferedPayloads.reserveCapacity(min(self.maxBatchSize, 256))
    }

    deinit {
        finish()
    }

    /// Retains one payload or delivers it synchronously, returning false on byte-budget overflow.
    @discardableResult
    func yield(_ data: Data) -> Bool {
        yieldResult(data) == .accepted
    }

    /// Retains one payload while preserving the distinction between capacity overflow and
    /// a dispatcher that was retired during a handler replacement.
    func yieldResult(
        _ data: Data,
        alreadyRetained: Bool = false
    ) -> YieldResult {
        guard !data.isEmpty else {
            reportOverflowIfNeeded()
            return .overflow
        }
        switch delivery {
        case .async:
            return yieldAsyncResult(data, alreadyRetained: alreadyRetained)
        case .immediate:
            return yieldImmediateResult(data, alreadyRetained: alreadyRetained)
        }
    }

    func finish() {
        terminate(flushingPendingPayloads: true)
    }

    func abort() {
        terminate(flushingPendingPayloads: false)
    }

    private func terminate(flushingPendingPayloads: Bool) {
        let immediateBatch: PendingBatch?

        dispatchLock.lock()
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            dispatchLock.unlock()
            return
        }
        isFinished = true
        flushTask?.cancel()
        flushTask = nil
        if flushingPendingPayloads {
            let finalBatch = takeBufferedBatchLocked()
            switch delivery {
            case .async:
                immediateBatch = nil
                if let finalBatch {
                    pendingAsyncBatches.append(finalBatch)
                    ensureAsyncWorkerLocked()
                }
            case .immediate:
                immediateBatch = finalBatch
            }
        } else {
            immediateBatch = nil
            workerTask?.cancel()
            dropUndeliveredPayloadsLocked()
        }
        lock.unlock()

        if let immediateBatch,
           case let .immediate(handler) = delivery {
            handler(immediateBatch.payloads)
            releaseRetainedCapacity(for: immediateBatch)
        }
        dispatchLock.unlock()
    }

    private func yieldAsyncResult(
        _ data: Data,
        alreadyRetained: Bool
    ) -> YieldResult {
        let shouldReportOverflow: Bool

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return .terminated
        }
        let startsNewBatch = bufferedPayloads.isEmpty
        guard canRetainLocallyLocked(data, startsNewBatch: startsNewBatch),
              alreadyRetained || retainedCapacityBudget.reserve(
                  bytes: data.count,
                  payloadCount: 1,
                  startsNewBatch: startsNewBatch
              ) else {
            shouldReportOverflow = markOverflowLocked()
            lock.unlock()
            if shouldReportOverflow { onOverflow() }
            return .overflow
        }

        if startsNewBatch {
            retainedBatchCount += 1
        }
        retainedBytes += data.count
        retainedPayloadCount += 1
        bufferedPayloadBytes += data.count
        bufferedPayloads.append(data)
        if bufferedPayloads.count >= maxBatchSize || flushesPartialBatchesImmediately {
            if let batch = takeBufferedBatchLocked() {
                pendingAsyncBatches.append(batch)
                ensureAsyncWorkerLocked()
            }
        } else {
            scheduleFlushLocked()
        }
        lock.unlock()
        return .accepted
    }

    /// Immediate delivery remains synchronous. A partial batch is flushed before adding a
    /// payload that would otherwise cross the byte budget.
    private func yieldImmediateResult(
        _ data: Data,
        alreadyRetained: Bool
    ) -> YieldResult {
        dispatchLock.lock()
        defer { dispatchLock.unlock() }

        guard data.count <= maximumBufferedBytes else {
            reportOverflowIfNeeded()
            return .overflow
        }

        let precedingBatch: PendingBatch?
        let readyBatch: PendingBatch?
        let acceptedWithoutPrecedingFlush: Bool
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return .terminated
        }
        let startsNewBatch = bufferedPayloads.isEmpty
        if canRetainLocallyLocked(data, startsNewBatch: startsNewBatch),
           alreadyRetained || retainedCapacityBudget.reserve(
               bytes: data.count,
               payloadCount: 1,
               startsNewBatch: startsNewBatch
           ) {
            if startsNewBatch {
                retainedBatchCount += 1
            }
            retainedBytes += data.count
            retainedPayloadCount += 1
            bufferedPayloadBytes += data.count
            bufferedPayloads.append(data)
            readyBatch = bufferedPayloads.count >= maxBatchSize
                ? takeBufferedBatchLocked()
                : nil
            precedingBatch = nil
            acceptedWithoutPrecedingFlush = true
        } else {
            precedingBatch = takeBufferedBatchLocked()
            readyBatch = nil
            acceptedWithoutPrecedingFlush = false
        }
        lock.unlock()

        if acceptedWithoutPrecedingFlush {
            if let readyBatch,
               case let .immediate(handler) = delivery {
                handler(readyBatch.payloads)
                releaseRetainedCapacity(for: readyBatch)
            }
            return .accepted
        }
        if precedingBatch == nil {
            reportOverflowIfNeeded()
            return .overflow
        }
        if let precedingBatch,
           case let .immediate(handler) = delivery {
            handler(precedingBatch.payloads)
            releaseRetainedCapacity(for: precedingBatch)
        }

        let retriedReadyBatch: PendingBatch?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return .terminated
        }
        let retryStartsNewBatch = bufferedPayloads.isEmpty
        guard canRetainLocallyLocked(data, startsNewBatch: retryStartsNewBatch),
              alreadyRetained || retainedCapacityBudget.reserve(
                  bytes: data.count,
                  payloadCount: 1,
                  startsNewBatch: retryStartsNewBatch
              ) else {
            lock.unlock()
            reportOverflowIfNeeded()
            return .overflow
        }
        if retryStartsNewBatch {
            retainedBatchCount += 1
        }
        retainedBytes += data.count
        retainedPayloadCount += 1
        bufferedPayloadBytes += data.count
        bufferedPayloads.append(data)
        retriedReadyBatch = bufferedPayloads.count >= maxBatchSize
            ? takeBufferedBatchLocked()
            : nil
        lock.unlock()

        if let retriedReadyBatch,
           case let .immediate(handler) = delivery {
            handler(retriedReadyBatch.payloads)
            releaseRetainedCapacity(for: retriedReadyBatch)
        }
        return .accepted
    }

    private func canRetainLocallyLocked(
        _ data: Data,
        startsNewBatch: Bool
    ) -> Bool {
        data.count <= maximumBufferedBytes - retainedBytes &&
            retainedPayloadCount < maximumBufferedPayloadCount &&
            (!startsNewBatch || retainedBatchCount < maximumBufferedBatchCount)
    }

    private func scheduleFlushLocked() {
        guard flushTask == nil else { return }
        flushTask = Task.detached(priority: .userInitiated) { [weak self, maxDelay] in
            do {
                try await Task.sleep(for: maxDelay)
            } catch {
                return
            }
            self?.flushScheduledBatch()
        }
    }

    private func flushScheduledBatch() {
        lock.lock()
        guard !isFinished else {
            flushTask = nil
            lock.unlock()
            return
        }
        flushTask = nil
        if let batch = takeBufferedBatchLocked() {
            pendingAsyncBatches.append(batch)
            ensureAsyncWorkerLocked()
        }
        lock.unlock()
    }

    private func ensureAsyncWorkerLocked() {
        guard workerTask == nil else { return }
        workerTask = Task(priority: .userInitiated) { [self] in
            await runAsyncWorker()
        }
    }

    private func runAsyncWorker() async {
        guard case let .async(handler) = delivery else { return }

        while !Task.isCancelled, let batch = takeNextAsyncBatch() {
            guard !Task.isCancelled else {
                releaseRetainedCapacity(for: batch)
                break
            }
            await handler(batch.payloads)
            releaseRetainedCapacity(for: batch)
        }
    }

    private func takeNextAsyncBatch() -> PendingBatch? {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingAsyncBatches.isEmpty else {
            workerTask = nil
            return nil
        }
        return pendingAsyncBatches.removeFirst()
    }

    private func takeBufferedBatchLocked() -> PendingBatch? {
        guard !bufferedPayloads.isEmpty else { return nil }
        let batch = PendingBatch(
            payloads: bufferedPayloads,
            byteCount: bufferedPayloadBytes
        )
        bufferedPayloads.removeAll(keepingCapacity: true)
        bufferedPayloadBytes = 0
        flushTask?.cancel()
        flushTask = nil
        return batch
    }

    private func releaseRetainedCapacity(for batch: PendingBatch) {
        lock.lock()
        retainedBytes = max(0, retainedBytes - batch.byteCount)
        retainedPayloadCount = max(0, retainedPayloadCount - batch.payloadCount)
        retainedBatchCount = max(0, retainedBatchCount - 1)
        lock.unlock()
        retainedCapacityBudget.release(
            bytes: batch.byteCount,
            payloadCount: batch.payloadCount,
            batchCount: 1
        )
    }

    private func dropUndeliveredPayloadsLocked() {
        let bufferedBatchCount = bufferedPayloads.isEmpty ? 0 : 1
        let droppedBytes = bufferedPayloadBytes + pendingAsyncBatches.reduce(0) { $0 + $1.byteCount }
        let droppedPayloadCount = bufferedPayloads.count + pendingAsyncBatches.reduce(0) {
            $0 + $1.payloadCount
        }
        let droppedBatchCount = bufferedBatchCount + pendingAsyncBatches.count
        bufferedPayloads.removeAll(keepingCapacity: false)
        bufferedPayloadBytes = 0
        pendingAsyncBatches.removeAll(keepingCapacity: false)
        retainedBytes = max(0, retainedBytes - droppedBytes)
        retainedPayloadCount = max(0, retainedPayloadCount - droppedPayloadCount)
        retainedBatchCount = max(0, retainedBatchCount - droppedBatchCount)
        retainedCapacityBudget.release(
            bytes: droppedBytes,
            payloadCount: droppedPayloadCount,
            batchCount: droppedBatchCount
        )
    }

    private func reportOverflowIfNeeded() {
        lock.lock()
        let shouldReportOverflow = markOverflowLocked()
        lock.unlock()
        if shouldReportOverflow { onOverflow() }
    }

    private func markOverflowLocked() -> Bool {
        guard !didReportOverflow else { return false }
        didReportOverflow = true
        return true
    }

}
