//
//  LoomTransferSchedulerTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Transfer Scheduler", .serialized)
struct LoomTransferSchedulerTests {
    @Test("Small transfers receive extra weighted turns under a constrained global window")
    func smallTransfersReceiveExtraTurns() async {
        let chunkSize = 16 * 1024
        let scheduler = LoomTransferScheduler(
            configuration: LoomTransferConfiguration(
                chunkSize: chunkSize,
                perTransferWindowBytes: chunkSize,
                globalWindowBytes: chunkSize,
                smallObjectThresholdBytes: chunkSize * 2
            )
        )
        let largeTransferID = UUID()
        let smallTransferID = UUID()
        let recorder = SchedulerGrantRecorder()

        await scheduler.registerTransfer(id: largeTransferID, remainingBytes: UInt64(chunkSize * 3))
        await scheduler.registerTransfer(id: smallTransferID, remainingBytes: UInt64(chunkSize * 2))

        let firstLargeGrant = await scheduler.acquireChunk(
            for: largeTransferID,
            remainingBytes: UInt64(chunkSize * 3)
        )
        #expect(firstLargeGrant == chunkSize)

        let secondLargeGrantTask = Task<Int, Never> {
            let grant = await scheduler.acquireChunk(
                for: largeTransferID,
                remainingBytes: UInt64(chunkSize * 2)
            )
            await recorder.record(largeTransferID)
            return grant
        }
        let firstSmallGrantTask = Task<Int, Never> {
            let grant = await scheduler.acquireChunk(
                for: smallTransferID,
                remainingBytes: UInt64(chunkSize * 2)
            )
            await recorder.record(smallTransferID)
            return grant
        }

        try? await Task.sleep(for: .milliseconds(10))
        await scheduler.releaseChunk(
            for: largeTransferID,
            bytes: firstLargeGrant,
            remainingBytes: UInt64(chunkSize * 2)
        )
        #expect(await waitUntil { await recorder.count() >= 1 })
        #expect(await recorder.order() == [smallTransferID])

        let firstSmallGrant = await firstSmallGrantTask.value
        #expect(firstSmallGrant == chunkSize)

        let secondSmallGrantTask = Task<Int, Never> {
            let grant = await scheduler.acquireChunk(
                for: smallTransferID,
                remainingBytes: UInt64(chunkSize)
            )
            await recorder.record(smallTransferID)
            return grant
        }

        try? await Task.sleep(for: .milliseconds(10))
        await scheduler.releaseChunk(
            for: smallTransferID,
            bytes: firstSmallGrant,
            remainingBytes: UInt64(chunkSize)
        )
        #expect(await waitUntil { await recorder.count() >= 2 })
        #expect(await recorder.order() == [smallTransferID, smallTransferID])

        let secondSmallGrant = await secondSmallGrantTask.value
        #expect(secondSmallGrant == chunkSize)

        await scheduler.releaseChunk(
            for: smallTransferID,
            bytes: secondSmallGrant,
            remainingBytes: 0
        )
        #expect(await waitUntil { await recorder.count() >= 3 })
        #expect(await recorder.order() == [smallTransferID, smallTransferID, largeTransferID])

        let secondLargeGrant = await secondLargeGrantTask.value
        #expect(secondLargeGrant == chunkSize)

        await scheduler.finishTransfer(id: smallTransferID)
        await scheduler.finishTransfer(id: largeTransferID)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor SchedulerGrantRecorder {
    private var grantOrder: [UUID] = []

    func record(_ transferID: UUID) {
        grantOrder.append(transferID)
    }

    func count() -> Int {
        grantOrder.count
    }

    func order() -> [UUID] {
        grantOrder
    }
}
