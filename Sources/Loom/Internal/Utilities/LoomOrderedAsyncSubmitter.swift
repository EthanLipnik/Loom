//
//  LoomOrderedAsyncSubmitter.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/30/26.
//

import Foundation

package final class LoomOrderedAsyncSubmitter: @unchecked Sendable {
    private struct PendingOperation {
        let operation: (@escaping @Sendable () -> Void) -> Void
        let deadlineUptime: TimeInterval?
        let dropsWhenExpired: Bool
        let dropsWhenQueueFull: Bool
        let queueFullDropPriority: Int
        let onExpired: @Sendable () -> Void
        let onQueueLimit: @Sendable () -> Void
        let onDropped: @Sendable () -> Void
    }

    private let stateLock = NSLock()
    private var pendingOperations: [PendingOperation] = []
    private var isProcessing = false
    private var isClosed = false

    package init() {}

    package func enqueue(
        operation: @escaping (@escaping @Sendable () -> Void) -> Void,
        deadlineUptime: TimeInterval? = nil,
        dropsWhenExpired: Bool = false,
        maxPendingOperations: Int? = nil,
        dropsWhenQueueFull: Bool = false,
        queueFullDropPriority: Int = Int.max,
        onExpired: @escaping @Sendable () -> Void = {},
        onQueueLimit: @escaping @Sendable () -> Void = {},
        onDropped: @escaping @Sendable () -> Void
    ) {
        stateLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let expiredOperations = removeExpiredOperationsLocked(now: now)
        if dropsWhenExpired, let deadlineUptime, now >= deadlineUptime {
            stateLock.unlock()
            expiredOperations.forEach { $0.onExpired() }
            onExpired()
            return
        }
        if isClosed {
            stateLock.unlock()
            expiredOperations.forEach { $0.onExpired() }
            onDropped()
            return
        }
        let normalizedMaxPendingOperations = maxPendingOperations.map { max(0, $0) }
        let droppedForQueueLimit: PendingOperation?
        if let normalizedMaxPendingOperations,
           pendingOperations.count >= normalizedMaxPendingOperations,
           normalizedMaxPendingOperations > 0 || isProcessing {
            if let dropIndex = queueLimitDropIndexLocked(
                incomingDropsWhenQueueFull: dropsWhenQueueFull,
                incomingQueueFullDropPriority: queueFullDropPriority
            ) {
                droppedForQueueLimit = pendingOperations.remove(at: dropIndex)
            } else if dropsWhenQueueFull {
                stateLock.unlock()
                expiredOperations.forEach { $0.onExpired() }
                onQueueLimit()
                return
            } else {
                droppedForQueueLimit = nil
            }
        } else {
            droppedForQueueLimit = nil
        }
        pendingOperations.append(PendingOperation(
            operation: operation,
            deadlineUptime: deadlineUptime,
            dropsWhenExpired: dropsWhenExpired,
            dropsWhenQueueFull: dropsWhenQueueFull,
            queueFullDropPriority: queueFullDropPriority,
            onExpired: onExpired,
            onQueueLimit: onQueueLimit,
            onDropped: onDropped
        ))
        let nextOperation: PendingOperation?
        if isProcessing {
            nextOperation = nil
        } else {
            isProcessing = true
            nextOperation = pendingOperations.removeFirst()
        }
        stateLock.unlock()
        expiredOperations.forEach { $0.onExpired() }
        droppedForQueueLimit?.onQueueLimit()

        guard let nextOperation else { return }
        run(nextOperation)
    }

    package func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        let droppedOperations = pendingOperations
        pendingOperations.removeAll(keepingCapacity: false)
        stateLock.unlock()
        droppedOperations.forEach { $0.onDropped() }
    }

    private func run(_ operation: PendingOperation) {
        operation.operation { [weak self] in
            self?.completeOperation()
        }
    }

    private func completeOperation() {
        stateLock.lock()
        let expiredOperations = removeExpiredOperationsLocked(now: ProcessInfo.processInfo.systemUptime)
        let nextOperation = pendingOperations.isEmpty ? nil : pendingOperations.removeFirst()
        if nextOperation == nil {
            isProcessing = false
        }
        stateLock.unlock()
        expiredOperations.forEach { $0.onExpired() }
        guard let nextOperation else { return }
        run(nextOperation)
    }

    private func removeExpiredOperationsLocked(now: TimeInterval) -> [PendingOperation] {
        var expiredOperations: [PendingOperation] = []
        var index = pendingOperations.startIndex
        while index < pendingOperations.endIndex {
            let operation = pendingOperations[index]
            if operation.dropsWhenExpired,
               let deadline = operation.deadlineUptime,
               now >= deadline {
                expiredOperations.append(operation)
                pendingOperations.remove(at: index)
            } else {
                index = pendingOperations.index(after: index)
            }
        }
        return expiredOperations
    }

    private func queueLimitDropIndexLocked(
        incomingDropsWhenQueueFull: Bool,
        incomingQueueFullDropPriority: Int
    ) -> Array<PendingOperation>.Index? {
        guard !pendingOperations.isEmpty else { return nil }
        let dropIndex = pendingOperations.indices
            .filter { pendingOperations[$0].dropsWhenQueueFull }
            .min { lhs, rhs in
                pendingOperations[lhs].queueFullDropPriority <
                    pendingOperations[rhs].queueFullDropPriority
            }
        guard let dropIndex else { return nil }
        if pendingOperations[dropIndex].queueFullDropPriority <= incomingQueueFullDropPriority {
            return dropIndex
        }
        return incomingDropsWhenQueueFull ? nil : dropIndex
    }
}
