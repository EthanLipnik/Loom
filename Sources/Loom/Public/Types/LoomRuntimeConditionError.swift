//
//  LoomRuntimeConditionError.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Typed runtime conditions that are expected under specific peer/session states.
//

import Foundation

public enum LoomRuntimeConditionError: Int, Error, Sendable, Equatable, Hashable, Comparable, LocalizedError {
    case credentialsRequired = 1
    case approvalPending = 2

    public static func < (lhs: LoomRuntimeConditionError, rhs: LoomRuntimeConditionError) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var message: String {
        switch self {
        case .credentialsRequired:
            "Credentials are required"
        case .approvalPending:
            "Waiting for peer approval"
        }
    }

    public var errorDescription: String? {
        message
    }

    public static var diagnosticsDomain: String {
        String(reflecting: LoomRuntimeConditionError.self)
    }
}
