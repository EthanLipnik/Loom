//
//  LoomDiagnosticsTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Diagnostics fanout, error reporting, and context registry tests.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Diagnostics", .serialized)
struct LoomDiagnosticsTests {
    @Test("Multi-sink fanout delivers every log event")
    func multiSinkFanoutDeliversEvents() async {
        await LoomDiagnostics.removeAllSinks()

        let sinkOne = TestSink()
        let sinkTwo = TestSink()
        _ = await LoomDiagnostics.addSink(sinkOne)
        _ = await LoomDiagnostics.addSink(sinkTwo)

        let event = LoomDiagnosticsLogEvent(
            date: Date(),
            category: .session,
            level: .info,
            message: "fanout-event",
            fileID: #fileID,
            line: #line,
            function: #function
        )
        LoomDiagnostics.record(log: event)

        #expect(await waitUntil {
            let firstCount = await sinkOne.logCount()
            let secondCount = await sinkTwo.logCount()
            return firstCount >= 1 && secondCount >= 1
        })
    }

    @Test("Sink removal stops future deliveries")
    func sinkRemovalStopsFutureDeliveries() async {
        await LoomDiagnostics.removeAllSinks()

        let sink = TestSink()
        let sinkToken = await LoomDiagnostics.addSink(sink)

        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: Date(),
            category: .session,
            level: .info,
            message: "before-removal",
            fileID: #fileID,
            line: #line,
            function: #function
        ))
        #expect(await waitUntil { await sink.logCount() >= 1 })
        let baselineCount = await sink.logCount()

        await LoomDiagnostics.removeSink(sinkToken)
        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: Date(),
            category: .session,
            level: .info,
            message: "after-removal",
            fileID: #fileID,
            line: #line,
            function: #function
        ))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await sink.logCount() == baselineCount)
    }

    @Test("Structured report(error:) emits typed diagnostics metadata")
    func reportErrorEmitsStructuredMetadata() async {
        await LoomDiagnostics.removeAllSinks()

        let sink = TestSink()
        _ = await LoomDiagnostics.addSink(sink)

        let error = NSError(
            domain: "com.loom.tests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Sensitive text should not appear"]
        )
        LoomDiagnostics.report(
            error: error,
            category: .session,
            source: .report
        )

        #expect(await waitUntil { await sink.errorCount() == 1 })
        guard let event = await sink.firstError() else {
            Issue.record("Expected structured error event")
            return
        }

        #expect(event.category == .session)
        #expect(event.source == .report)
        #expect(event.metadata?.domain == "com.loom.tests")
        #expect(event.metadata?.code == 42)
        #expect(event.metadata?.typeName.contains("NSError") == true)
        #expect(event.message.contains("Sensitive text should not appear") == false)
    }

    @Test("run wrapper reports exactly once and rethrows original error")
    func runWrapperReportsOnceAndRethrows() async {
        await LoomDiagnostics.removeAllSinks()

        let sink = TestSink()
        _ = await LoomDiagnostics.addSink(sink)

        let expected = NSError(domain: "com.loom.tests.run", code: 777)
        do {
            _ = try await LoomDiagnostics.run(category: .transport, message: "run wrapper failure") {
                throw expected
            } as Int
            Issue.record("Expected LoomDiagnostics.run to rethrow")
        } catch {
            let rethrown = error as NSError
            #expect(rethrown.domain == expected.domain)
            #expect(rethrown.code == expected.code)
        }

        #expect(await waitUntil { await sink.errorCount() == 1 })
        guard let event = await sink.firstError() else {
            Issue.record("Expected run wrapper diagnostics event")
            return
        }

        #expect(event.source == .run)
        #expect(event.category == .transport)
        #expect(event.metadata?.domain == expected.domain)
        #expect(event.metadata?.code == expected.code)
    }

    @Test("Context provider registry snapshots active providers only")
    func contextProviderRegistrySnapshotsActiveProviders() async {
        await LoomDiagnostics.removeAllSinks()

        let firstToken = await LoomDiagnostics.registerContextProvider {
            ["provider.one": .int(1), "shared.key": .string("first")]
        }
        let secondToken = await LoomDiagnostics.registerContextProvider {
            ["provider.two": .bool(true), "shared.key": .string("second")]
        }

        let fullSnapshot = await LoomDiagnostics.snapshotContext()
        #expect(fullSnapshot["provider.one"] == .int(1))
        #expect(fullSnapshot["provider.two"] == .bool(true))
        #expect(fullSnapshot["shared.key"] == .string("second"))

        await LoomDiagnostics.unregisterContextProvider(secondToken)
        let partialSnapshot = await LoomDiagnostics.snapshotContext()
        #expect(partialSnapshot["provider.one"] == .int(1))
        #expect(partialSnapshot["provider.two"] == nil)
        #expect(partialSnapshot["shared.key"] == .string("first"))

        await LoomDiagnostics.unregisterContextProvider(firstToken)
    }

    @Test("Privacy-safe metadata path avoids localized error strings in fallback message")
    func privacySafeFallbackMessageOmitsLocalizedDescription() async {
        await LoomDiagnostics.removeAllSinks()

        let sink = TestSink()
        _ = await LoomDiagnostics.addSink(sink)

        let sensitiveMessage = "hostname=internal.example.local user=ethan"
        let error = NSError(
            domain: "com.loom.tests.privacy",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: sensitiveMessage]
        )
        LoomDiagnostics.report(error: error, category: .transport)

        #expect(await waitUntil { await sink.errorCount() == 1 })
        guard let event = await sink.firstError() else {
            Issue.record("Expected privacy-safe diagnostics event")
            return
        }

        #expect(event.message.contains("type="))
        #expect(event.message.contains("domain="))
        #expect(event.message.contains("code="))
        #expect(event.message.contains(sensitiveMessage) == false)
    }

    @Test("Cancelled tasks still dispatch diagnostics events when sinks are present")
    func cancelledTasksStillDispatchDiagnosticsEvents() async {
        await LoomDiagnostics.removeAllSinks()

        let sink = TestSink()
        _ = await LoomDiagnostics.addSink(sink)

        let event = LoomDiagnosticsLogEvent(
            date: Date(),
            category: .session,
            level: .info,
            message: "cancelled-task-log",
            fileID: #fileID,
            line: #line,
            function: #function
        )

        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            LoomDiagnostics.record(log: event)
        }
        let baselineCount = await sink.logCount()
        _ = await task.result

        #expect(await waitUntil { await sink.logCount() >= baselineCount + 1 })
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

private actor TestSink: LoomDiagnosticsSink {
    private var logs: [LoomDiagnosticsLogEvent] = []
    private var errors: [LoomDiagnosticsErrorEvent] = []

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event)
    }

    func record(error event: LoomDiagnosticsErrorEvent) async {
        errors.append(event)
    }

    func logCount() -> Int {
        logs.count
    }

    func errorCount() -> Int {
        errors.count
    }

    func firstError() -> LoomDiagnosticsErrorEvent? {
        errors.first
    }
}
