//
//  LoomNetworkFrameworkStreamReceivePumpTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/17/26.
//

#if canImport(Network)
@testable import Loom
import Foundation
import Testing

@Suite("Network.framework Stream Receive Pump")
struct LoomNetworkFrameworkStreamReceivePumpTests {
    @Test("Receive pump rearms before resuming the current consumer")
    func receivePumpRearmsBeforeResumingCurrentConsumer() async throws {
        let driver = TestStreamReceiveDriver()
        let pump = LoomNetworkFrameworkStreamReceivePump(driver: driver)
        pump.start()
        let receiveTask = Task { try await pump.receive(maximumBytes: 1_200) }
        await Task.yield()

        driver.deliver(.chunk(Data([1]), endOfStream: false))

        #expect(driver.pendingReceiveCount == 1)
        #expect(try await receiveTask.value == Data([1]))
    }

    @Test("Receive pump remains armed while the consumer is between reads")
    func receivePumpRemainsArmedBetweenConsumerReads() async throws {
        let driver = TestStreamReceiveDriver()
        let pump = LoomNetworkFrameworkStreamReceivePump(driver: driver)
        pump.start()

        driver.deliver(.chunk(Data([1]), endOfStream: false))
        driver.deliver(.chunk(Data([2]), endOfStream: false))
        driver.deliver(.chunk(Data([3]), endOfStream: false))

        #expect(driver.pendingReceiveCount == 1)
        #expect(try await pump.receive(maximumBytes: 1) == Data([1]))
        #expect(try await pump.receive(maximumBytes: 1) == Data([2]))
        #expect(try await pump.receive(maximumBytes: 1) == Data([3]))
    }

    @Test("Bounded buffering pauses and resumes receive registration")
    func boundedBufferingPausesAndResumesReceiveRegistration() async throws {
        let driver = TestStreamReceiveDriver()
        let pump = LoomNetworkFrameworkStreamReceivePump(
            driver: driver,
            maximumReceiveBytes: 2,
            maximumQueuedBytes: 4,
            maximumQueuedChunkCount: 2
        )
        pump.start()

        driver.deliver(.chunk(Data([1, 2]), endOfStream: false))
        #expect(driver.pendingReceiveCount == 1)
        driver.deliver(.chunk(Data([3, 4]), endOfStream: false))
        #expect(driver.pendingReceiveCount == 0)

        #expect(try await pump.receive(maximumBytes: 2) == Data([1, 2]))
        #expect(driver.pendingReceiveCount == 1)
        #expect(try await pump.receive(maximumBytes: 2) == Data([3, 4]))
    }

    @Test("Receive limit splits a buffered stream chunk without losing order")
    func receiveLimitSplitsBufferedStreamChunk() async throws {
        let driver = TestStreamReceiveDriver()
        let pump = LoomNetworkFrameworkStreamReceivePump(
            driver: driver,
            maximumReceiveBytes: 4,
            maximumQueuedBytes: 8
        )
        pump.start()

        driver.deliver(.chunk(Data([1, 2, 3, 4]), endOfStream: false))

        #expect(try await pump.receive(maximumBytes: 2) == Data([1, 2]))
        #expect(try await pump.receive(maximumBytes: 2) == Data([3, 4]))
    }

    @Test("Orderly close preserves accepted stream input")
    func orderlyClosePreservesAcceptedStreamInput() async throws {
        let driver = TestStreamReceiveDriver()
        let pump = LoomNetworkFrameworkStreamReceivePump(driver: driver)
        pump.start()

        driver.deliver(.chunk(Data([1, 2]), endOfStream: true))

        #expect(driver.pendingReceiveCount == 0)
        #expect(try await pump.receive(maximumBytes: 1) == Data([1]))
        #expect(try await pump.receive(maximumBytes: 1) == Data([2]))
        #expect(try await pump.receive(maximumBytes: 1) == nil)
    }

    @Test("Failure preserves accepted stream input before surfacing the error")
    func failurePreservesAcceptedStreamInput() async throws {
        let driver = TestStreamReceiveDriver()
        let pump = LoomNetworkFrameworkStreamReceivePump(driver: driver)
        let expectedError = LoomNetworkError(code: .networkDown, detail: "test failure")
        pump.start()

        driver.deliver(.chunk(Data([1]), endOfStream: false))
        driver.deliver(.failed(expectedError))

        #expect(try await pump.receive(maximumBytes: 1) == Data([1]))
        await #expect(throws: LoomNetworkError.self) {
            try await pump.receive(maximumBytes: 1)
        }
    }

    @Test("Cancelling one waiter cannot cancel its successor")
    func cancellingOneWaiterCannotCancelItsSuccessor() async throws {
        let driver = TestStreamReceiveDriver()
        let pump = LoomNetworkFrameworkStreamReceivePump(driver: driver)
        pump.start()

        let firstReceive = Task { try await pump.receive(maximumBytes: 1) }
        await Task.yield()
        firstReceive.cancel()
        await #expect(throws: CancellationError.self) {
            try await firstReceive.value
        }

        let secondReceive = Task { try await pump.receive(maximumBytes: 1) }
        await Task.yield()
        driver.deliver(.chunk(Data([2]), endOfStream: false))

        #expect(try await secondReceive.value == Data([2]))
    }
}

private final class TestStreamReceiveDriver: LoomNetworkFrameworkStreamReceiveDriver, @unchecked Sendable {
    typealias Completion = @Sendable (LoomNetworkFrameworkStreamReceiveEvent) -> Void

    private struct PendingReceive {
        let maximumBytes: Int
        let completion: Completion
    }

    private let lock = NSLock()
    private var pendingReceives: [PendingReceive] = []

    var pendingReceiveCount: Int {
        lock.lock()
        let count = pendingReceives.count
        lock.unlock()
        return count
    }

    func receiveStreamChunk(maximumBytes: Int, completion: @escaping Completion) {
        lock.lock()
        pendingReceives.append(PendingReceive(
            maximumBytes: maximumBytes,
            completion: completion
        ))
        lock.unlock()
    }

    func deliver(_ event: LoomNetworkFrameworkStreamReceiveEvent) {
        let pendingReceive: PendingReceive
        lock.lock()
        pendingReceive = pendingReceives.removeFirst()
        lock.unlock()

        if case let .chunk(data, _) = event {
            #expect(data.count <= pendingReceive.maximumBytes)
        }
        pendingReceive.completion(event)
    }
}
#endif
