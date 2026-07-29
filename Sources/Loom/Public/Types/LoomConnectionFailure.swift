//
//  LoomConnectionFailure.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/27/26.
//

import Foundation
import LoomNetworking
#if canImport(Network)
import Network
#endif

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
        if let loomError = error as? LoomError,
           case .timeout = loomError {
            return LoomConnectionFailure(reason: .timedOut, detail: loomError.localizedDescription)
        }

        if error is CancellationError {
            return LoomConnectionFailure(reason: .cancelled, detail: error.localizedDescription)
        }

        if let networkError = error as? LoomNetworkError {
            let reason: LoomConnectionFailureReason = switch networkError.code {
            case .cancelled:
                .cancelled
            case .closed:
                .closed
            case .connectionRefused:
                .connectionRefused
            case .timedOut:
                .timedOut
            case .networkDown, .unreachable:
                .transportLoss
            case .invalidConfiguration, .unsupported, .other:
                .other
            }
            return LoomConnectionFailure(reason: reason, detail: networkError.detail)
        }

#if canImport(Network)
        if let nwError = error as? NWError {
            return classify(nwError)
        }
#endif

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return classify(code, detail: nsError.localizedDescription)
        }

        return LoomConnectionFailure(reason: .other, detail: error.localizedDescription)
    }

#if canImport(Network)
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
#endif

    public static func classify(
        _ code: POSIXErrorCode,
        detail: String? = nil
    ) -> LoomConnectionFailure {
#if os(Windows)
        // Foundation's Windows POSIXErrorCode omits Winsock-only network cases.
        let reason: LoomConnectionFailureReason = switch code.rawValue {
        case 10060:
            .timedOut
        case 10061:
            .connectionRefused
        case 10049:
            .addressUnavailable
        case 10050, 10051, 10052, 10053, 10054, 10057, 10064, 10065:
            .transportLoss
        case 995:
            .cancelled
        default:
            .other
        }
#else
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
#endif

        return LoomConnectionFailure(
            reason: reason,
            posixCode: code,
            detail: detail
        )
    }
}
