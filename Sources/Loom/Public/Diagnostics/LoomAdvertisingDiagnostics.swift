//
//  LoomAdvertisingDiagnostics.swift
//  Loom
//
//  Created by Ethan Lipnik on 6/3/26.
//

import Foundation

/// Publication state for a Loom node that is accepting incoming sessions.
public enum LoomAdvertisingState: String, Codable, Equatable, Sendable {
    case idle
    case starting
    case advertising
    case recovering
    case failed
}

/// Diagnostics for the currently published incoming-session listener set.
public struct LoomAdvertisingDiagnostics: Codable, Equatable, Sendable {
    /// Current listener publication state.
    public let state: LoomAdvertisingState

    /// Bonjour service name currently being advertised, when available.
    public let serviceName: String?

    /// TCP Bonjour listener port currently published by Network.framework.
    public let bonjourPort: UInt16?

    /// Direct transport listener ports managed by Loom.
    public let directListenerPorts: [LoomTransportKind: UInt16]

    /// Most recent Bonjour advertiser failure description.
    public let lastBonjourFailureDescription: String?

    /// Time of the most recent Bonjour advertiser failure.
    public let lastBonjourFailureAt: Date?

    /// Consecutive Bonjour restart attempt number for the active recovery cycle.
    public let bonjourRecoveryAttempt: Int

    /// Creates an advertising diagnostics snapshot.
    public init(
        state: LoomAdvertisingState = .idle,
        serviceName: String? = nil,
        bonjourPort: UInt16? = nil,
        directListenerPorts: [LoomTransportKind: UInt16] = [:],
        lastBonjourFailureDescription: String? = nil,
        lastBonjourFailureAt: Date? = nil,
        bonjourRecoveryAttempt: Int = 0
    ) {
        self.state = state
        self.serviceName = serviceName
        self.bonjourPort = bonjourPort
        self.directListenerPorts = directListenerPorts
        self.lastBonjourFailureDescription = lastBonjourFailureDescription
        self.lastBonjourFailureAt = lastBonjourFailureAt
        self.bonjourRecoveryAttempt = bonjourRecoveryAttempt
    }

    /// Returns a copy with updated listener state while preserving failure history.
    public func updating(
        state: LoomAdvertisingState,
        serviceName: String? = nil,
        bonjourPort: UInt16? = nil,
        directListenerPorts: [LoomTransportKind: UInt16]? = nil,
        bonjourRecoveryAttempt: Int? = nil
    ) -> LoomAdvertisingDiagnostics {
        LoomAdvertisingDiagnostics(
            state: state,
            serviceName: serviceName ?? self.serviceName,
            bonjourPort: bonjourPort,
            directListenerPorts: directListenerPorts ?? self.directListenerPorts,
            lastBonjourFailureDescription: lastBonjourFailureDescription,
            lastBonjourFailureAt: lastBonjourFailureAt,
            bonjourRecoveryAttempt: bonjourRecoveryAttempt ?? self.bonjourRecoveryAttempt
        )
    }

    /// Returns a copy that records a Bonjour advertiser failure.
    public func recordingBonjourFailure(
        _ description: String,
        at date: Date,
        recoveryAttempt: Int
    ) -> LoomAdvertisingDiagnostics {
        LoomAdvertisingDiagnostics(
            state: .recovering,
            serviceName: serviceName,
            bonjourPort: nil,
            directListenerPorts: directListenerPorts,
            lastBonjourFailureDescription: description,
            lastBonjourFailureAt: date,
            bonjourRecoveryAttempt: recoveryAttempt
        )
    }
}
