//
//  LoomIncomingRetainedCapacityBudget.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Thread-safe retained byte and logical-payload accounting across an ingress hierarchy.
package final class LoomIncomingRetainedCapacityBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var maximumBytes: Int
    private var maximumPayloadCount: Int
    private var parent: LoomIncomingRetainedCapacityBudget?
    private var retainedBytes = 0
    private var retainedPayloadCount = 0

    init(
        maximumBytes: Int,
        maximumPayloadCount: Int,
        maximumBatchCount _: Int,
        parent: LoomIncomingRetainedCapacityBudget? = nil
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumPayloadCount = max(1, maximumPayloadCount)
        self.parent = parent
    }

    deinit {
        lock.lock()
        let parent = parent
        let retainedBytes = retainedBytes
        let retainedPayloadCount = retainedPayloadCount
        self.retainedBytes = 0
        self.retainedPayloadCount = 0
        if retainedBytes > 0 || retainedPayloadCount > 0 {
            parent?.release(
                bytes: retainedBytes,
                payloadCount: retainedPayloadCount,
                batchCount: 0
            )
        }
        lock.unlock()
    }

    func reserve(
        bytes: Int,
        payloadCount: Int,
        startsNewBatch _: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bytes >= 0,
              payloadCount >= 0,
              bytes > 0 || payloadCount > 0,
              bytes <= maximumBytes - retainedBytes,
              payloadCount <= maximumPayloadCount - retainedPayloadCount else {
            return false
        }
        guard parent?.reserve(
            bytes: bytes,
            payloadCount: payloadCount,
            startsNewBatch: false
        ) ?? true else {
            return false
        }
        retainedBytes += bytes
        retainedPayloadCount += payloadCount
        return true
    }

    func release(
        bytes: Int,
        payloadCount: Int,
        batchCount _: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        let parent = parent
        let releasedBytes = min(max(0, bytes), retainedBytes)
        let releasedPayloadCount = min(max(0, payloadCount), retainedPayloadCount)
        retainedBytes -= releasedBytes
        retainedPayloadCount -= releasedPayloadCount
        guard releasedBytes > 0 || releasedPayloadCount > 0 else { return }
        parent?.release(
            bytes: releasedBytes,
            payloadCount: releasedPayloadCount,
            batchCount: 0
        )
    }

    @discardableResult
    func setParentIfEmpty(_ parent: LoomIncomingRetainedCapacityBudget) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard parent !== self,
              self.parent == nil,
              retainedBytes == 0,
              retainedPayloadCount == 0 else {
            return false
        }
        self.parent = parent
        return true
    }

    func updateLimits(
        maximumBytes: Int,
        maximumPayloadCount: Int,
        maximumBatchCount _: Int
    ) {
        lock.lock()
        self.maximumBytes = max(1, maximumBytes)
        self.maximumPayloadCount = max(1, maximumPayloadCount)
        lock.unlock()
    }

    var retainedBytesForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedBytes
    }
}
