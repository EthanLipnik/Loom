//
//  LoomInstrumentationTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/24/26.
//
//  Instrumentation fanout and sink lifecycle behavior tests.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Instrumentation", .serialized)
struct LoomInstrumentationTests {
    fileprivate static let connectionRequested: LoomStepEvent = "loom.tests.connection.requested"
    fileprivate static let connectionEstablished: LoomStepEvent = "loom.tests.connection.established"
    fileprivate static let connectionFailed: LoomStepEvent = "loom.tests.connection.failed"
    fileprivate static let renderPipelineStarted: LoomStepEvent = "loom.tests.render.pipeline.started"

    @Test("Multi-sink fanout delivers every step event")
    func multiSinkFanoutDeliversEvents() async {
        await LoomInstrumentation.removeAllSinks()

        let sinkOne = TestInstrumentationSink()
        let sinkTwo = TestInstrumentationSink()
        _ = await LoomInstrumentation.addSink(sinkOne)
        _ = await LoomInstrumentation.addSink(sinkTwo)

        LoomInstrumentation.record(Self.connectionRequested)

        #expect(await waitUntil {
            let firstCount = await sinkOne.eventCount()
            let secondCount = await sinkTwo.eventCount()
            return firstCount >= 1 && secondCount >= 1
        })
    }

    @Test("Sink removal stops future instrumentation delivery")
    func sinkRemovalStopsFutureDeliveries() async {
        await LoomInstrumentation.removeAllSinks()

        let sink = TestInstrumentationSink()
        let sinkToken = await LoomInstrumentation.addSink(sink)

        LoomInstrumentation.record(Self.connectionRequested)
        #expect(await waitUntil { await sink.eventCount() >= 1 })
        let baselineCount = await sink.eventCount()

        await LoomInstrumentation.removeSink(sinkToken)
        LoomInstrumentation.record(Self.connectionEstablished)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await sink.eventCount() == baselineCount)
    }

    @Test("removeAllSinks clears all instrumentation recipients")
    func removeAllSinksStopsAllDeliveries() async {
        await LoomInstrumentation.removeAllSinks()

        let sinkOne = TestInstrumentationSink()
        let sinkTwo = TestInstrumentationSink()
        _ = await LoomInstrumentation.addSink(sinkOne)
        _ = await LoomInstrumentation.addSink(sinkTwo)

        LoomInstrumentation.record(Self.connectionRequested)
        #expect(await waitUntil {
            let firstCount = await sinkOne.eventCount()
            let secondCount = await sinkTwo.eventCount()
            return firstCount >= 1 && secondCount >= 1
        })

        let sinkOneBaseline = await sinkOne.eventCount()
        let sinkTwoBaseline = await sinkTwo.eventCount()

        await LoomInstrumentation.removeAllSinks()
        LoomInstrumentation.record(Self.connectionFailed)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await sinkOne.eventCount() == sinkOneBaseline)
        #expect(await sinkTwo.eventCount() == sinkTwoBaseline)
    }

    @Test("No sinks skip step construction")
    func noSinksSkipStepConstruction() async {
        await LoomInstrumentation.removeAllSinks()

        let probe = StepProbe()
        LoomInstrumentation.record(probe.nextStep())

        #expect(probe.callCount == 0)
    }

    @Test("Dispatch keeps step event identity")
    func dispatchKeepsStepIdentity() async {
        await LoomInstrumentation.removeAllSinks()

        let sink = TestInstrumentationSink()
        _ = await LoomInstrumentation.addSink(sink)
        let expectedStep = Self.renderPipelineStarted
        LoomInstrumentation.record(expectedStep)

        #expect(await waitUntil { await sink.eventCount() >= 1 })
        let event = await sink.latestEvent()
        #expect(event?.step == expectedStep)
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

private final class StepProbe {
    private(set) var callCount = 0

    func nextStep() -> LoomStepEvent {
        callCount += 1
        return LoomInstrumentationTests.connectionRequested
    }
}

private actor TestInstrumentationSink: LoomInstrumentationSink {
    private var events: [LoomInstrumentationEvent] = []

    func record(event: LoomInstrumentationEvent) async {
        events.append(event)
    }

    func eventCount() -> Int {
        events.count
    }

    func latestEvent() -> LoomInstrumentationEvent? {
        events.last
    }
}
