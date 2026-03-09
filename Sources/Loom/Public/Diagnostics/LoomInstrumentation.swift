//
//  LoomInstrumentation.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/24/26.
//
//  App-agnostic instrumentation hooks for Loom services.
//

import Foundation

/// String-backed instrumentation event identifier.
///
/// Loom intentionally keeps instrumentation names opaque so higher-level
/// products can define their own event taxonomy without baking product
/// semantics into the base package.
public struct LoomStepEvent: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public var name: String {
        rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }
}

public struct LoomInstrumentationEvent: Sendable, Equatable {
    public let step: LoomStepEvent
    public let timestamp: Date

    public var name: String {
        step.name
    }

    public init(
        step: LoomStepEvent,
        timestamp: Date = Date()
    ) {
        self.step = step
        self.timestamp = timestamp
    }
}

public struct LoomInstrumentationSinkToken: Hashable, Sendable {
    let rawValue = UUID()
}

public protocol LoomInstrumentationSink: Sendable {
    func record(event: LoomInstrumentationEvent) async
}

public extension LoomInstrumentationSink {
    func record(event _: LoomInstrumentationEvent) async {}
}

private final class LoomInstrumentationSinkRegistryState: @unchecked Sendable {
    private let lock = NSLock()
    private var sinkCount = 0

    var hasRegisteredSinks: Bool {
        withLock { sinkCount > 0 }
    }

    func setSinkCount(_ count: Int) {
        withLock {
            sinkCount = max(0, count)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let instrumentationSinkRegistryState = LoomInstrumentationSinkRegistryState()

private actor LoomInstrumentationStore {
    static let shared = LoomInstrumentationStore()

    private var sinks: [LoomInstrumentationSinkToken: any LoomInstrumentationSink] = [:]

    func addSink(_ sink: any LoomInstrumentationSink) -> LoomInstrumentationSinkToken {
        let token = LoomInstrumentationSinkToken()
        sinks[token] = sink
        instrumentationSinkRegistryState.setSinkCount(sinks.count)
        return token
    }

    func removeSink(_ token: LoomInstrumentationSinkToken) {
        sinks.removeValue(forKey: token)
        instrumentationSinkRegistryState.setSinkCount(sinks.count)
    }

    func removeAllSinks() {
        sinks.removeAll()
        instrumentationSinkRegistryState.setSinkCount(0)
    }

    func activeSinks() -> [any LoomInstrumentationSink] {
        Array(sinks.values)
    }
}

public enum LoomInstrumentation {
    @discardableResult
    public static func addSink(_ sink: some LoomInstrumentationSink) async -> LoomInstrumentationSinkToken {
        await LoomInstrumentationStore.shared.addSink(sink)
    }

    public static func removeSink(_ token: LoomInstrumentationSinkToken) async {
        await LoomInstrumentationStore.shared.removeSink(token)
    }

    public static func removeAllSinks() async {
        await LoomInstrumentationStore.shared.removeAllSinks()
    }

    public static func record(_ step: @autoclosure () -> LoomStepEvent) {
        guard instrumentationSinkRegistryState.hasRegisteredSinks else { return }

        let event = LoomInstrumentationEvent(step: step())
        Task {
            let sinks = await LoomInstrumentationStore.shared.activeSinks()
            await withTaskGroup(of: Void.self) { group in
                for sink in sinks {
                    group.addTask {
                        await sink.record(event: event)
                    }
                }
            }
        }
    }
}
