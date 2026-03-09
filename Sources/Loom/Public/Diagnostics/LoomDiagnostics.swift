//
//  LoomDiagnostics.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Public diagnostics reporting primitives for Loom-powered app integrations.
//

import Foundation

public enum LoomDiagnosticsValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([LoomDiagnosticsValue])
    case dictionary([String: LoomDiagnosticsValue])
    case null

    public var foundationValue: Any {
        switch self {
        case let .string(value):
            value
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .array(values):
            values.map(\.foundationValue)
        case let .dictionary(values):
            values.mapValues(\.foundationValue)
        case .null:
            NSNull()
        }
    }
}

public typealias LoomDiagnosticsContext = [String: LoomDiagnosticsValue]

public struct LoomDiagnosticsSinkToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct LoomDiagnosticsContextProviderToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct LoomDiagnosticsLogEvent: Sendable {
    public let date: Date
    public let category: LoomLogCategory
    public let level: LoomLogLevel
    public let message: String
    public let fileID: String
    public let line: UInt
    public let function: String

    public init(
        date: Date,
        category: LoomLogCategory,
        level: LoomLogLevel,
        message: String,
        fileID: String,
        line: UInt,
        function: String
    ) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
        self.fileID = fileID
        self.line = line
        self.function = function
    }
}

public enum LoomDiagnosticsErrorSeverity: String, Sendable {
    case error
    case fault
}

public enum LoomDiagnosticsErrorSource: String, Sendable {
    case logger
    case report
    case run
}

public struct LoomDiagnosticsErrorMetadata: Sendable, Equatable {
    public let typeName: String
    public let domain: String
    public let code: Int

    public init(typeName: String, domain: String, code: Int) {
        self.typeName = typeName
        self.domain = domain
        self.code = code
    }

    public init(error: Error) {
        let nsError = error as NSError
        self.init(
            typeName: String(reflecting: type(of: error)),
            domain: nsError.domain,
            code: nsError.code
        )
    }
}

public struct LoomDiagnosticsErrorEvent: Sendable {
    public let date: Date
    public let category: LoomLogCategory
    public let severity: LoomDiagnosticsErrorSeverity
    public let source: LoomDiagnosticsErrorSource
    public let message: String
    public let fileID: String
    public let line: UInt
    public let function: String
    public let metadata: LoomDiagnosticsErrorMetadata?

    public init(
        date: Date,
        category: LoomLogCategory,
        severity: LoomDiagnosticsErrorSeverity,
        source: LoomDiagnosticsErrorSource,
        message: String,
        fileID: String,
        line: UInt,
        function: String,
        metadata: LoomDiagnosticsErrorMetadata?
    ) {
        self.date = date
        self.category = category
        self.severity = severity
        self.source = source
        self.message = message
        self.fileID = fileID
        self.line = line
        self.function = function
        self.metadata = metadata
    }
}

public protocol LoomDiagnosticsSink: Sendable {
    func record(log event: LoomDiagnosticsLogEvent) async
    func record(error event: LoomDiagnosticsErrorEvent) async
}

public extension LoomDiagnosticsSink {
    func record(log _: LoomDiagnosticsLogEvent) async {}
    func record(error _: LoomDiagnosticsErrorEvent) async {}
}

public typealias LoomDiagnosticsContextProvider = @Sendable () async -> LoomDiagnosticsContext

private final class LoomDiagnosticsSinkRegistryState: @unchecked Sendable {
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

private enum LoomDiagnosticsDispatchItem: Sendable {
    case log(LoomDiagnosticsLogEvent)
    case error(LoomDiagnosticsErrorEvent)
}

private let diagnosticsSinkRegistryState = LoomDiagnosticsSinkRegistryState()
private let diagnosticsDispatchQueue = LoomAsyncDispatchQueue<LoomDiagnosticsDispatchItem>(priority: .utility) { item in
    switch item {
    case let .log(event):
        await LoomDiagnosticsStore.shared.record(log: event)
    case let .error(event):
        await LoomDiagnosticsStore.shared.record(error: event)
    }
}

actor LoomDiagnosticsStore {
    static let shared = LoomDiagnosticsStore()

    private var sinks: [LoomDiagnosticsSinkToken: any LoomDiagnosticsSink] = [:]
    private var contextProviders: [LoomDiagnosticsContextProviderToken: LoomDiagnosticsContextProvider] = [:]
    private var contextProviderOrder: [LoomDiagnosticsContextProviderToken] = []

    func addSink(_ sink: any LoomDiagnosticsSink) -> LoomDiagnosticsSinkToken {
        let token = LoomDiagnosticsSinkToken()
        sinks[token] = sink
        diagnosticsSinkRegistryState.setSinkCount(sinks.count)
        return token
    }

    func removeSink(_ token: LoomDiagnosticsSinkToken) {
        sinks.removeValue(forKey: token)
        diagnosticsSinkRegistryState.setSinkCount(sinks.count)
    }

    func removeAllSinks() {
        sinks.removeAll()
        diagnosticsSinkRegistryState.setSinkCount(0)
    }

    func registerContextProvider(_ provider: @escaping LoomDiagnosticsContextProvider) -> LoomDiagnosticsContextProviderToken {
        let token = LoomDiagnosticsContextProviderToken()
        contextProviders[token] = provider
        contextProviderOrder.append(token)
        return token
    }

    func unregisterContextProvider(_ token: LoomDiagnosticsContextProviderToken) {
        contextProviders.removeValue(forKey: token)
        contextProviderOrder.removeAll { $0 == token }
    }

    func snapshotContext() async -> LoomDiagnosticsContext {
        var snapshot: LoomDiagnosticsContext = [:]
        let orderedProviders = contextProviderOrder.compactMap { contextProviders[$0] }
        for provider in orderedProviders {
            let context = await provider()
            snapshot.merge(context, uniquingKeysWith: { _, newValue in newValue })
        }
        return snapshot
    }

    func record(log event: LoomDiagnosticsLogEvent) async {
        let sinks = Array(sinks.values)
        for sink in sinks {
            await sink.record(log: event)
        }
    }

    func record(error event: LoomDiagnosticsErrorEvent) async {
        let sinks = Array(sinks.values)
        for sink in sinks {
            await sink.record(error: event)
        }
    }
}

public enum LoomDiagnostics {
    public static var hasRegisteredSinks: Bool {
        diagnosticsSinkRegistryState.hasRegisteredSinks
    }

    @discardableResult
    public static func addSink(_ sink: any LoomDiagnosticsSink) async -> LoomDiagnosticsSinkToken {
        await LoomDiagnosticsStore.shared.addSink(sink)
    }

    public static func removeSink(_ token: LoomDiagnosticsSinkToken) async {
        await LoomDiagnosticsStore.shared.removeSink(token)
    }

    public static func removeAllSinks() async {
        await LoomDiagnosticsStore.shared.removeAllSinks()
    }

    @discardableResult
    public static func registerContextProvider(
        _ provider: @escaping LoomDiagnosticsContextProvider
    ) async -> LoomDiagnosticsContextProviderToken {
        await LoomDiagnosticsStore.shared.registerContextProvider(provider)
    }

    public static func unregisterContextProvider(_ token: LoomDiagnosticsContextProviderToken) async {
        await LoomDiagnosticsStore.shared.unregisterContextProvider(token)
    }

    public static func snapshotContext() async -> LoomDiagnosticsContext {
        await LoomDiagnosticsStore.shared.snapshotContext()
    }

    public static func report(
        error: Error,
        category: LoomLogCategory,
        severity: LoomDiagnosticsErrorSeverity = .error,
        source: LoomDiagnosticsErrorSource = .report,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        let metadata = LoomDiagnosticsErrorMetadata(error: error)
        let renderedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackMessage =
            "[\(fileID):\(line) \(function)] type=\(metadata.typeName) domain=\(metadata.domain) code=\(metadata.code)"
        let event = LoomDiagnosticsErrorEvent(
            date: Date(),
            category: category,
            severity: severity,
            source: source,
            message: (renderedMessage?.isEmpty == false ? renderedMessage : nil) ?? fallbackMessage,
            fileID: fileID,
            line: line,
            function: function,
            metadata: metadata
        )
        record(error: event)
    }

    public static func run<T>(
        category: LoomLogCategory,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            report(
                error: error,
                category: category,
                source: .run,
                message: message,
                fileID: fileID,
                line: line,
                function: function
            )
            throw error
        }
    }

    public static func record(log event: LoomDiagnosticsLogEvent) {
        guard diagnosticsSinkRegistryState.hasRegisteredSinks else { return }
        diagnosticsDispatchQueue.yield(.log(event))
    }

    public static func record(error event: LoomDiagnosticsErrorEvent) {
        guard diagnosticsSinkRegistryState.hasRegisteredSinks else { return }
        diagnosticsDispatchQueue.yield(.error(event))
    }
}
