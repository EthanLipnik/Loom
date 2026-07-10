//
//  LoomIncomingRetainedCapacityBudgetTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

@testable import Loom
import Dispatch
import Testing

@Suite("Incoming Retained Capacity Budget")
struct LoomIncomingRetainedCapacityBudgetTests {
    @Test("Over-release from one child cannot free a sibling's parent reservation")
    func overReleaseDoesNotUndercountParent() {
        let parent = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 10,
            maximumPayloadCount: 10,
            maximumBatchCount: 10
        )
        let firstChild = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 10,
            maximumPayloadCount: 10,
            maximumBatchCount: 10,
            parent: parent
        )
        let secondChild = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 10,
            maximumPayloadCount: 10,
            maximumBatchCount: 10,
            parent: parent
        )

        #expect(firstChild.reserve(bytes: 6, payloadCount: 1, startsNewBatch: true))
        #expect(secondChild.reserve(bytes: 4, payloadCount: 1, startsNewBatch: true))
        firstChild.release(bytes: 100, payloadCount: 100, batchCount: 100)

        #expect(parent.retainedBytesForTesting == 4)
        #expect(!secondChild.reserve(bytes: 7, payloadCount: 1, startsNewBatch: true))
        #expect(secondChild.reserve(bytes: 6, payloadCount: 1, startsNewBatch: true))
    }

    @Test("Byte-only reservations support fragment storage")
    func byteOnlyReservations() {
        let budget = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 10,
            maximumPayloadCount: 1,
            maximumBatchCount: 1
        )

        #expect(budget.reserve(bytes: 4, payloadCount: 1, startsNewBatch: true))
        #expect(budget.reserve(bytes: 6, payloadCount: 0, startsNewBatch: false))
        #expect(!budget.reserve(bytes: 1, payloadCount: 0, startsNewBatch: false))
    }

    @Test("Concurrent child reserve and release cannot leak parent accounting")
    func concurrentReserveReleaseIsAtomicAcrossHierarchy() {
        let parent = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 100_000,
            maximumPayloadCount: 100_000,
            maximumBatchCount: 100_000
        )
        let child = LoomIncomingRetainedCapacityBudget(
            maximumBytes: 100_000,
            maximumPayloadCount: 100_000,
            maximumBatchCount: 100_000,
            parent: parent
        )

        DispatchQueue.concurrentPerform(iterations: 20_000) { _ in
            if child.reserve(bytes: 1, payloadCount: 1, startsNewBatch: true) {
                child.release(bytes: 1, payloadCount: 1, batchCount: 1)
            }
        }

        #expect(child.retainedBytesForTesting == 0)
        #expect(parent.retainedBytesForTesting == 0)
    }
}
