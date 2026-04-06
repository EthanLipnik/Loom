//
//  LoomConnectionFailure.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/27/26.
//

import Foundation
import Network

public enum LoomConnectionFailureReason: String, Sendable, Codable {
    case cancelled
    case closed
    case timedOut
    case transportLoss
    case connectionRefused
    case addressUnavailable
    case other
}

public struct LoomConnectionFailure: Error, LocalizedError, Sendable {
    public let reason: LoomConnectionFailureReason
    public let posixCode: POSIXErrorCode?
    public let detail: String?

    public init(
        reason: LoomConnectionFailureReason,
        posixCode: POSIXErrorCode? = nil,
        detail: String? = nil
    ) {
        self.reason = reason
        self.posixCode = posixCode
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var errorDescription: String? {
        if let detail, !detail.isEmpty {
            return detail
        }

        return switch reason {
        case .cancelled:
            "Connection cancelled."
        case .closed:
            "Connection closed."
        case .timedOut:
            "Connection timed out."
        case .transportLoss:
            "Connection lost."
        case .connectionRefused:
            "Connection refused."
        case .addressUnavailable:
            "Address unavailable."
        case .other:
            "Connection failed."
        }
    }

    public static func classify(_ error: Error) -> LoomConnectionFailure {
        if let failure = error as? LoomConnectionFailure {
            return failure
        }

        if let loomError = error as? LoomError,
           case let .connectionFailed(underlying) = loomError {
            return classify(underlying)
        }

        if error is CancellationError {
            return LoomConnectionFailure(reason: .cancelled, detail: error.localizedDescription)
        }

        if let nwError = error as? NWError {
            return classify(nwError)
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return classify(code, detail: nsError.localizedDescription)
        }

        return LoomConnectionFailure(reason: .other, detail: error.localizedDescription)
    }

    public static func classify(_ error: NWError) -> LoomConnectionFailure {
        switch error {
        case let .posix(code):
            return classify(code, detail: error.localizedDescription)
        case .dns:
            return LoomConnectionFailure(reason: .addressUnavailable, detail: error.localizedDescription)
        case .tls:
            return LoomConnectionFailure(reason: .other, detail: error.localizedDescription)
        case .wifiAware:
            return LoomConnectionFailure(reason: .other, detail: error.localizedDescription)
        @unknown default:
            return LoomConnectionFailure(reason: .other, detail: error.localizedDescription)
        }
    }

    public static func classify(
        _ code: POSIXErrorCode,
        detail: String? = nil
    ) -> LoomConnectionFailure {
        let reason: LoomConnectionFailureReason = switch code {
        case .ETIMEDOUT:
            .timedOut
        case .ECONNREFUSED:
            .connectionRefused
        case .EADDRNOTAVAIL:
            .addressUnavailable
        case .ENETDOWN,
             .ENETUNREACH,
             .EHOSTDOWN,
             .EHOSTUNREACH,
             .ENETRESET,
             .ECONNABORTED,
             .ECONNRESET,
             .ENOTCONN,
             .EPIPE:
            .transportLoss
        case .ECANCELED:
            .cancelled
        default:
            .other
        }

        return LoomConnectionFailure(
            reason: reason,
            posixCode: code,
            detail: detail
        )
    }
}
