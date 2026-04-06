//
//  LoomCloudKitPeerManager+Compatibility.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/11/26.
//

import CloudKit
import Foundation

public extension LoomCloudKitPeerManager {
    nonisolated static func shouldRetryRegistrationWithoutBootstrapMetadata(
        error: Error,
        attemptedBootstrapMetadataWrite: Bool
    ) -> Bool {
        attemptedBootstrapMetadataWrite && isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldRetryRegistrationWithoutOptionalPeerMetadata(
        error: Error,
        attemptedOptionalPeerMetadataWrite: Bool
    ) -> Bool {
        attemptedOptionalPeerMetadataWrite && isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldRetryRegistrationWithMinimalRecordFields(
        error: Error,
        attemptedRichPeerMetadataWrite: Bool
    ) -> Bool {
        attemptedRichPeerMetadataWrite && isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldIgnoreParticipantIdentityRecordFailure(_ error: Error) -> Bool {
        isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldIgnoreExistingPeerRecordQueryFailure(_ error: Error) -> Bool {
        isMissingPeerRecordZoneCloudKitError(error)
    }

    nonisolated static func shouldIgnoreStaleOwnPeerCleanupFailure(_ error: Error) -> Bool {
        isMissingPeerRecordZoneCloudKitError(error)
    }

    nonisolated static func isMissingProductionSchemaRecordTypeError(
        _ error: Error,
        recordType: String
    ) -> Bool {
        let loweredExpectedMessage = "cannot create new type \(recordType.lowercased()) in production schema"
        return cloudKitErrorMessages(for: error).contains { message in
            message.lowercased().contains(loweredExpectedMessage)
        }
    }

    nonisolated static func isInvalidArgumentsCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        return nsError.code == CKError.Code.invalidArguments.rawValue
    }

    nonisolated static func isUnknownItemCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        return nsError.code == CKError.Code.unknownItem.rawValue
    }

    nonisolated static func isMissingPeerRecordZoneCloudKitError(_ error: Error) -> Bool {
        isUnknownItemCloudKitError(error) || isMissingPeerZoneCloudKitError(error)
    }

    nonisolated static func isMissingPeerZoneCloudKitError(_ error: Error) -> Bool {
        isMissingPeerZoneCloudKitError(error as NSError)
    }

    private nonisolated static func isMissingPeerZoneCloudKitError(_ error: NSError) -> Bool {
        if error.domain == CKError.errorDomain,
           error.code == CKError.Code.zoneNotFound.rawValue {
            return true
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           isMissingPeerZoneCloudKitError(underlyingError) {
            return true
        }

        if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] {
            for value in partialErrors.values {
                guard let nestedError = value as? NSError else { continue }
                if isMissingPeerZoneCloudKitError(nestedError) {
                    return true
                }
            }
        }

        return false
    }

    private nonisolated static func cloudKitErrorMessages(for error: Error) -> [String] {
        var messages: [String] = []
        var visitedErrors = Set<ObjectIdentifier>()

        func appendMessages(from value: Any) {
            switch value {
            case let nestedError as NSError:
                let identifier = ObjectIdentifier(nestedError)
                guard visitedErrors.insert(identifier).inserted else { return }
                messages.append(nestedError.localizedDescription)
                for nestedValue in nestedError.userInfo.values {
                    appendMessages(from: nestedValue)
                }
            case let nestedError as Error:
                appendMessages(from: nestedError as NSError)
            case let array as [Any]:
                for element in array {
                    appendMessages(from: element)
                }
            case let dictionary as [AnyHashable: Any]:
                for nestedValue in dictionary.values {
                    appendMessages(from: nestedValue)
                }
            case let message as String:
                messages.append(message)
            default:
                break
            }
        }

        appendMessages(from: error)
        return messages
    }
}
