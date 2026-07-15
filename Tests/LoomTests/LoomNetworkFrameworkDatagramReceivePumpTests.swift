//
//  LoomNetworkFrameworkDatagramReceivePumpTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/14/26.
//

#if canImport(Network)
@testable import Loom
import Foundation
import Testing

@Suite("Network.framework Datagram Receive Pump")
struct LoomNetworkFrameworkDatagramReceivePumpTests {
    @Test("Receive pump rearms before resuming the current consumer")
    func receivePumpRearmsBeforeResumingCurrentConsumer() async throws {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(driver: driver)
        pump.start()
        let receiveTask = Task { try await pump.receive(maximumBytes: 1_200) }
        await Task.yield()

        driver.deliver(.datagram(Data([1])))

        #expect(driver.pendingReceiveCount == 1)
        #expect(try await receiveTask.value == Data([1]))
    }

    @Test("Orderly close preserves accepted FIFO input")
    func orderlyClosePreservesAcceptedFIFOInput() async throws {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(driver: driver)
        pump.start()

        driver.deliver(.datagram(Data([1])))
        driver.deliver(.datagram(Data([2])))
        driver.deliver(.closed)

        #expect(try await pump.receive(maximumBytes: 1_200) == Data([1]))
        #expect(try await pump.receive(maximumBytes: 1_200) == Data([2]))
        #expect(try await pump.receive(maximumBytes: 1_200) == nil)
    }

    @Test("Failure preserves accepted FIFO input before surfacing the error")
    func failurePreservesAcceptedFIFOInput() async throws {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(driver: driver)
        let expectedError = LoomNetworkError(code: .networkDown, detail: "test failure")
        pump.start()

        driver.deliver(.datagram(Data([1])))
        driver.deliver(.datagram(Data([2])))
        driver.deliver(.failed(expectedError))

        #expect(try await pump.receive(maximumBytes: 1_200) == Data([1]))
        #expect(try await pump.receive(maximumBytes: 1_200) == Data([2]))
        await #expect(throws: LoomNetworkError.self) {
            try await pump.receive(maximumBytes: 1_200)
        }
    }

    @Test("Bounded overflow stops receive rearming")
    func boundedOverflowStopsReceiveRearming() async throws {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(
            driver: driver,
            maximumQueuedBytes: 2,
            maximumQueuedCount: 1
        )
        pump.start()

        driver.deliver(.datagram(Data([1])))
        #expect(driver.pendingReceiveCount == 1)
        driver.deliver(.datagram(Data([2])))

        #expect(driver.pendingReceiveCount == 0)
        #expect(try await pump.receive(maximumBytes: 1_200) == Data([1]))
        await #expect(throws: LoomNetworkError.self) {
            try await pump.receive(maximumBytes: 1_200)
        }
    }

    @Test("Explicit cancellation discards input and ignores stale callbacks")
    func explicitCancellationDiscardsInputAndIgnoresStaleCallbacks() async {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(driver: driver)
        pump.start()
        let cancellationError = LoomNetworkError(code: .cancelled, detail: "test cancellation")

        pump.cancel(with: cancellationError)
        driver.deliver(.datagram(Data([1])))

        #expect(driver.pendingReceiveCount == 0)
        await #expect(throws: LoomNetworkError.self) {
            try await pump.receive(maximumBytes: 1_200)
        }
    }

    @Test(arguments: [false, true])
    func explicitCancellationOverridesRecordedTerminalState(recordFailure: Bool) async {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(driver: driver)
        pump.start()
        let recordedError = LoomNetworkError(code: .networkDown, detail: "recorded failure")
        let cancellationError = LoomNetworkError(code: .cancelled, detail: "test cancellation")

        driver.deliver(.datagram(Data([1])))
        driver.deliver(recordFailure ? .failed(recordedError) : .closed)
        pump.cancel(with: cancellationError)

        await #expect(throws: LoomNetworkError.self) {
            try await pump.receive(maximumBytes: 1_200)
        }
    }

    @Test("Cancelling one waiter cannot cancel its successor")
    func cancellingOneWaiterCannotCancelItsSuccessor() async throws {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(driver: driver)
        pump.start()

        let firstReceive = Task { try await pump.receive(maximumBytes: 1_200) }
        await Task.yield()
        firstReceive.cancel()
        await #expect(throws: CancellationError.self) {
            try await firstReceive.value
        }

        let secondReceive = Task { try await pump.receive(maximumBytes: 1_200) }
        await Task.yield()
        driver.deliver(.datagram(Data([2])))

        #expect(try await secondReceive.value == Data([2]))
    }

    @Test("Indexed FIFO preserves order across a large drain")
    func indexedFIFOPreservesOrderAcrossLargeDrain() async throws {
        let driver = TestDatagramReceiveDriver()
        let pump = LoomNetworkFrameworkDatagramReceivePump(driver: driver)
        pump.start()
        let count = 2_048

        for value in 0 ..< count {
            driver.deliver(.datagram(withUnsafeBytes(of: UInt16(value).bigEndian) { Data($0) }))
        }

        for expectedValue in 0 ..< count {
            let data = try #require(await pump.receive(maximumBytes: 2))
            let value = data.reduce(UInt16(0)) { partial, byte in
                (partial << 8) | UInt16(byte)
            }
            #expect(value == UInt16(expectedValue))
        }
    }
}

private final class TestDatagramReceiveDriver: LoomNetworkFrameworkDatagramReceiveDriver, @unchecked Sendable {
    typealias Completion = @Sendable (LoomNetworkFrameworkDatagramReceiveEvent) -> Void

    private let lock = NSLock()
    private var completions: [Completion] = []

    var pendingReceiveCount: Int {
        lock.lock()
        let count = completions.count
        lock.unlock()
        return count
    }

    func receiveMessage(completion: @escaping Completion) {
        lock.lock()
        completions.append(completion)
        lock.unlock()
    }

    func deliver(_ event: LoomNetworkFrameworkDatagramReceiveEvent) {
        let completion: Completion
        lock.lock()
        completion = completions.removeFirst()
        lock.unlock()
        completion(event)
    }
}
#endif
