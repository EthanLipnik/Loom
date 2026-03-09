//
//  LoomBootstrapControlProtocol.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Authenticated line-based JSON protocol used for peer bootstrap control handoff.
//

import CryptoKit
import Foundation

/// Bootstrap control operation kind.
public enum LoomBootstrapControlOperation: String, Codable, Sendable {
    case status
    case submitCredentials
}

/// Signed bootstrap control request envelope.
public struct LoomBootstrapControlAuthEnvelope: Codable, Sendable, Equatable {
    /// Identity key identifier for the signing key.
    public let keyID: String
    /// Raw P-256 signing public key.
    public let publicKey: Data
    /// Millisecond timestamp used for replay protection.
    public let timestampMs: Int64
    /// Per-request nonce.
    public let nonce: String
    /// DER-encoded signature over canonical request bytes.
    public let signature: Data

    public init(
        keyID: String,
        publicKey: Data,
        timestampMs: Int64,
        nonce: String,
        signature: Data
    ) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.timestampMs = timestampMs
        self.nonce = nonce
        self.signature = signature
    }
}

/// Encrypted credential payload for bootstrap control.
public struct LoomBootstrapEncryptedCredentialsPayload: Codable, Sendable, Equatable {
    /// ChaCha20-Poly1305 combined payload (`ciphertext + auth tag + nonce` wrapper omitted).
    public let combined: Data

    public init(combined: Data) {
        self.combined = combined
    }
}

/// Bootstrap control request payload sent to a peer bootstrap daemon.
public struct LoomBootstrapControlRequest: Codable, Sendable {
    /// Correlation identifier for request/response matching.
    public let requestID: UUID
    /// Operation to execute.
    public let operation: LoomBootstrapControlOperation
    /// Signed request authentication envelope.
    public let auth: LoomBootstrapControlAuthEnvelope
    /// Encrypted credentials payload for credential-submission operations.
    public let credentialsPayload: LoomBootstrapEncryptedCredentialsPayload?

    /// Creates a bootstrap daemon control request payload.
    public init(
        requestID: UUID = UUID(),
        operation: LoomBootstrapControlOperation,
        auth: LoomBootstrapControlAuthEnvelope,
        credentialsPayload: LoomBootstrapEncryptedCredentialsPayload? = nil
    ) {
        self.requestID = requestID
        self.operation = operation
        self.auth = auth
        self.credentialsPayload = credentialsPayload
    }
}

/// Bootstrap control response payload returned by a peer bootstrap daemon.
public struct LoomBootstrapControlResponse: Codable, Sendable {
    /// Correlation identifier for request/response matching.
    public let requestID: UUID
    /// Whether the requested operation succeeded.
    public let success: Bool
    /// Availability observed after operation.
    public let availability: LoomSessionAvailability
    /// Human-readable message for diagnostics and remediation.
    public let message: String?
    /// Whether the request can be retried.
    public let canRetry: Bool
    /// Remaining retries available (if bounded by peer policy).
    public let retriesRemaining: Int?
    /// Cooldown before retry is allowed.
    public let retryAfterSeconds: Int?

    /// Creates a daemon control response payload.
    public init(
        requestID: UUID,
        success: Bool,
        availability: LoomSessionAvailability,
        message: String?,
        canRetry: Bool,
        retriesRemaining: Int?,
        retryAfterSeconds: Int?
    ) {
        self.requestID = requestID
        self.success = success
        self.availability = availability
        self.message = message
        self.canRetry = canRetry
        self.retriesRemaining = retriesRemaining
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Decrypted credentials for daemon credential-submission requests.
public struct LoomBootstrapCredentials: Codable, Sendable, Equatable {
    public let userIdentifier: String?
    public let secret: String

    public init(userIdentifier: String?, secret: String) {
        self.userIdentifier = userIdentifier
        self.secret = secret
    }
}

public enum LoomBootstrapControlSecurity {
    private static let keyContext = Data("loom-bootstrap-control".utf8)

    public static func canonicalPayload(
        requestID: UUID,
        operation: LoomBootstrapControlOperation,
        encryptedPayloadSHA256: String,
        keyID: String,
        timestampMs: Int64,
        nonce: String
    ) throws -> Data {
        try LoomIdentitySigning.bootstrapControlPayload(
            requestID: requestID,
            operationRawValue: operation.rawValue,
            encryptedPayloadSHA256: encryptedPayloadSHA256,
            keyID: keyID,
            timestampMs: timestampMs,
            nonce: nonce
        )
    }

    public static func payloadSHA256Hex(_ data: Data?) -> String {
        let digest = SHA256.hash(data: data ?? Data("-".utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    public static func encryptCredentials(
        _ credentials: LoomBootstrapCredentials,
        sharedSecret: String,
        requestID: UUID,
        timestampMs: Int64,
        nonce: String
    ) throws -> LoomBootstrapEncryptedCredentialsPayload {
        let plaintext = try JSONEncoder().encode(credentials)
        let key = try deriveEncryptionKey(
            sharedSecret: sharedSecret,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        return LoomBootstrapEncryptedCredentialsPayload(combined: sealed.combined)
    }

    public static func decryptCredentials(
        _ payload: LoomBootstrapEncryptedCredentialsPayload,
        sharedSecret: String,
        requestID: UUID,
        timestampMs: Int64,
        nonce: String
    ) throws -> LoomBootstrapCredentials {
        let key = try deriveEncryptionKey(
            sharedSecret: sharedSecret,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let sealed = try ChaChaPoly.SealedBox(combined: payload.combined)
        let plaintext = try ChaChaPoly.open(sealed, using: key)
        return try JSONDecoder().decode(LoomBootstrapCredentials.self, from: plaintext)
    }

    private static func deriveEncryptionKey(
        sharedSecret: String,
        requestID: UUID,
        timestampMs: Int64,
        nonce: String
    ) throws -> SymmetricKey {
        let trimmedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            throw LoomError.protocolError("Bootstrap control secret is empty")
        }
        guard nonce.utf8.count <= LoomMessageLimits.maxReplayNonceLength else {
            throw LoomError.protocolError("Bootstrap control nonce is too long")
        }

        let secretData = Data(trimmedSecret.utf8)
        let saltText = "\(requestID.uuidString.lowercased())|\(timestampMs)|\(nonce)"
        let salt = Data(SHA256.hash(data: Data(saltText.utf8)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secretData),
            salt: salt,
            info: keyContext,
            outputByteCount: 32
        )
    }
}
