//
//  LoomVirtualAppSessionDeadlineTests.swift
//  LoomSharedRuntimeTests
//
//  Created by Ethan Lipnik on 8/1/26.
//

@testable import Loom
@testable import LoomSharedRuntime
import Foundation
import Testing

@Suite("Loom virtual app session deadlines", .serialized)
struct LoomVirtualAppSessionDeadlineTests {
    @Test("Expired deadline admits no IPC request and leaves the session usable")
    func expiredDeadlineIsNondestructiveBeforeAdmission() async throws {
        let probe = VirtualAppSessionDeadlineProbe()
        let stream = try await makeStream(probe: probe)

        await #expect(throws: LoomError.self) {
            try await stream.send(
                Data([1]),
                hardDeadline: ContinuousClock.now - .milliseconds(1)
            )
        }

        #expect(await probe.sendCount == 0)
        #expect(await probe.hardCutCount == 0)
        try await stream.send(Data([2]))
        #expect(await probe.sendCount == 1)
    }

    @Test("Deadline hard cut quiesces its lease and fences later IPC requests")
    func hardCutQuiescesAndFencesLaterRequests() async throws {
        let probe = VirtualAppSessionDeadlineProbe(suspendsSends: true)
        let stream = try await makeStream(probe: probe)
        let sendTask = Task<Result<Void, any Error>, Never> {
            do {
                try await stream.send(
                    Data([1]),
                    hardDeadline: ContinuousClock.now + .milliseconds(100)
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        #expect(await waitForVirtualSessionCondition { await probe.sendCount == 1 })
        let result = await sendTask.value
        if case .success = result {
            Issue.record("A suspended IPC request unexpectedly survived its hard deadline.")
        }
        #expect(await probe.hardCutCount == 1)

        do {
            try await stream.send(
                Data([2]),
                hardDeadline: ContinuousClock.now + .seconds(1)
            )
            Issue.record("A hard-cut virtual session admitted a later IPC request.")
        } catch {
            // The closed admission fence, rather than the IPC handler, owns this rejection.
        }
        #expect(await probe.sendCount == 1)
    }

    @Test("IPC failure releases the transferred lease without closing admission")
    func operationFailureReleasesTransferredLease() async throws {
        let probe = VirtualAppSessionDeadlineProbe(throwsFromSend: true)
        let stream = try await makeStream(probe: probe)

        await #expect(throws: VirtualAppSessionDeadlineProbe.Failure.self) {
            try await stream.send(
                Data([1]),
                hardDeadline: ContinuousClock.now + .seconds(1)
            )
        }
        #expect(await probe.sendCount == 1)
        #expect(await probe.hardCutCount == 0)

        await probe.setThrowsFromSend(false)
        try await stream.send(Data([2]))
        #expect(await probe.sendCount == 2)
    }

    private func makeStream(
        probe: VirtualAppSessionDeadlineProbe
    ) async throws -> LoomMultiplexedStream {
        let session = LoomVirtualAppSession(
            connectionID: UUID(),
            transportKind: .tcp,
            context: nil,
            openHandler: { _, _, _ in },
            sendHandler: { _, _, _ in try await probe.send() },
            closeHandler: { _, _ in },
            cancelHandler: { _ in },
            hardCutHandler: { _ in await probe.hardCut() }
        )
        return try await session.openStream(label: "deadline-test")
    }
}

private actor VirtualAppSessionDeadlineProbe {
    struct Failure: Error {}

    private(set) var sendCount = 0
    private(set) var hardCutCount = 0
    private var suspendsSends: Bool
    private var throwsFromSend: Bool
    private var sendContinuation: CheckedContinuation<Void, Never>?

    init(suspendsSends: Bool = false, throwsFromSend: Bool = false) {
        self.suspendsSends = suspendsSends
        self.throwsFromSend = throwsFromSend
    }

    func send() async throws {
        sendCount += 1
        if throwsFromSend { throw Failure() }
        guard suspendsSends else { return }
        await withCheckedContinuation { continuation in
            sendContinuation = continuation
        }
    }

    func hardCut() {
        hardCutCount += 1
        suspendsSends = false
        sendContinuation?.resume()
        sendContinuation = nil
    }

    func setThrowsFromSend(_ enabled: Bool) {
        throwsFromSend = enabled
    }
}

private func waitForVirtualSessionCondition(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
