//
//  LoomBootstrapTelemetryEventEnvelope.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Shared queue envelope for daemon telemetry handoff to coordinator app reporting.
//

import Foundation

public enum LoomBootstrapTelemetryEventKind: String, Codable, Sendable {
    case analytics
    case diagnostic
}

public enum LoomBootstrapTelemetryEventSource: String, Codable, Sendable {
    case daemon
}

public struct LoomBootstrapTelemetryEventEnvelope: Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let kind: LoomBootstrapTelemetryEventKind
    public let eventName: String
    public let message: String?
    public let metadata: [String: String]
    public let source: LoomBootstrapTelemetryEventSource

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: LoomBootstrapTelemetryEventKind,
        eventName: String,
        message: String? = nil,
        metadata: [String: String] = [:],
        source: LoomBootstrapTelemetryEventSource = .daemon
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.eventName = eventName
        self.message = message
        self.metadata = metadata
        self.source = source
    }
}

public enum LoomBootstrapTelemetryQueueConstants {
    public static let fileName = "daemon-telemetry-queue.jsonl"
    public static let maxFileBytes = 1_048_576
    public static let maxEntries = 1_024
}
