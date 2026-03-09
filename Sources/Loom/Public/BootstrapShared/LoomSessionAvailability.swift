//
//  LoomSessionAvailability.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Shared peer availability and credential-submission error types used by bootstrap flows.
//

import Foundation

public enum LoomSessionAvailability: String, Codable, Sendable {
    case ready
    case credentialsRequired
    case credentialsAndUserIdentifierRequired
    case unavailable

    public var requiresCredentials: Bool {
        switch self {
        case .ready:
            false
        case .credentialsRequired,
             .credentialsAndUserIdentifierRequired,
             .unavailable:
            true
        }
    }

    public var requiresUserIdentifier: Bool {
        switch self {
        case .credentialsAndUserIdentifierRequired:
            true
        case .ready,
             .credentialsRequired,
             .unavailable:
            false
        }
    }

    public var isReady: Bool {
        self == .ready
    }
}

public struct LoomCredentialSubmissionError: Codable, Sendable, Equatable {
    public let code: LoomCredentialSubmissionErrorCode
    public let message: String

    public init(code: LoomCredentialSubmissionErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum LoomCredentialSubmissionErrorCode: String, Codable, Sendable {
    case invalidCredentials
    case rateLimited
    case sessionExpired
    case notReady
    case notSupported
    case notAuthorized
    case timeout
    case internalError
}
