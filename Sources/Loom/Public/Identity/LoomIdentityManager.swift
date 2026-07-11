//
//  LoomIdentityManager.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Account-scoped signing identity backed by Keychain-synchronized P256 keys.
//

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LoomNetworking
#if os(Windows)
import LoomPlatformAdapters
#endif

/// Public identity metadata for Loom authenticated handshakes.
public struct LoomAccountIdentity: Sendable, Equatable {
    /// Stable key identifier derived from the public key digest.
    public let keyID: String

    /// Uncompressed ANSI X9.63 representation (`0x04 || x || y`) of the signing public key.
    public let publicKey: Data

    /// Creates a public identity descriptor.
    ///
    /// - Parameters:
    ///   - keyID: Stable digest-derived identifier for the public key.
    ///   - publicKey: Uncompressed ANSI X9.63 P-256 signing public key bytes.
    public init(keyID: String, publicKey: Data) {
        self.keyID = keyID
        self.publicKey = publicKey
    }
}

/// Storage backing for a Loom account identity key.
public enum LoomIdentityStorage: Sendable, Equatable {
    /// Persist the identity key in Keychain on Apple platforms.
    ///
    /// On Windows this source-compatible spelling uses current-user DPAPI storage.
    case keychain

    /// Keep the identity key only in process memory.
    case memory
}

/// Manages the account signing key used by Loom handshake and API request signatures.
///
/// The key is stored in Keychain with synchronization enabled so it propagates
/// across the user's iCloud Keychain environment.
@MainActor
public final class LoomIdentityManager {
    /// Shared singleton used by default across Loom services.
    public static let shared = LoomIdentityManager()

    private let keyStorage: any LoomIdentityKeyStorage
    private var cachedPrivateKey: P256.Signing.PrivateKey?
    private var cachedIdentity: LoomAccountIdentity?

    /// Creates an identity manager.
    ///
    /// - Parameters:
    ///   - service: Keychain service name.
    ///   - account: Keychain account key.
    ///   - synchronizable: Whether to enable iCloud Keychain sync.
    ///   - fallbackToNonSynchronizableStorage: Whether to fall back to local-only Keychain storage when a
    ///     synchronized write is unavailable.
    ///   - storage: Storage backing for the generated identity key.
    public init(
        service: String = "com.loom.identity.account.v2",
        account: String = "p256-signing",
        synchronizable: Bool = true,
        fallbackToNonSynchronizableStorage: Bool = false,
        storage: LoomIdentityStorage = .keychain
    ) {
        keyStorage = Self.makeDefaultKeyStorage(
            service: service,
            account: account,
            synchronizable: synchronizable,
            fallbackToNonSynchronizableStorage: fallbackToNonSynchronizableStorage,
            storage: storage
        )
    }

    /// Creates an identity manager with an explicitly supplied protected-key backend.
    ///
    /// This overload is primarily for deterministic tests and platform adapters.
    public init(
        service: String,
        account: String,
        synchronizable: Bool,
        fallbackToNonSynchronizableStorage: Bool,
        storage: LoomIdentityStorage,
        identityKeyStorage: any LoomIdentityKeyStorage
    ) {
        keyStorage = identityKeyStorage
    }

    /// Creates an identity manager whose key is never persisted outside the process.
    public static func inMemory() -> LoomIdentityManager {
        LoomIdentityManager(
            synchronizable: false,
            storage: .memory
        )
    }

    /// Returns the active account identity, creating one when missing.
    public func currentIdentity() throws -> LoomAccountIdentity {
        if let cachedIdentity { return cachedIdentity }
        let key = try loadOrCreatePrivateKey()
        let publicKey = key.publicKey.x963Representation
        let identity = LoomAccountIdentity(
            keyID: Self.keyID(for: publicKey),
            publicKey: publicKey
        )
        cachedIdentity = identity
        return identity
    }

    /// Signs a payload with the current account key.
    ///
    /// - Parameter payload: Canonical bytes to sign.
    /// - Returns: DER-encoded ECDSA signature bytes.
    public func sign(_ payload: Data) throws -> Data {
        let key = try loadOrCreatePrivateKey()
        let signature = try key.signature(for: payload)
        return signature.derRepresentation
    }

    /// Derives shared key bytes with a peer P-256 public key.
    ///
    /// Uses ECDH followed by HKDF-SHA256 expansion.
    /// - Parameters:
    ///   - peerPublicKey: Uncompressed ANSI X9.63 P-256 public key bytes from the peer.
    ///   - salt: HKDF salt bytes.
    ///   - sharedInfo: HKDF context bytes.
    ///   - outputByteCount: Derived key size in bytes.
    public func deriveSharedKey(
        with peerPublicKey: Data,
        salt: Data,
        sharedInfo: Data,
        outputByteCount: Int = 32
    ) throws -> Data {
        let signingKey = try loadOrCreatePrivateKey()
        let agreementKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: signingKey.rawRepresentation)
        let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        let sharedSecret = try agreementKey.sharedSecretFromKeyAgreement(with: peerKey)
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: sharedInfo,
            outputByteCount: outputByteCount
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }

    /// Rotates the account signing key and returns the new identity.
    public func rotateIdentity() throws -> LoomAccountIdentity {
        try keyStorage.deletePrivateKey()
        cachedPrivateKey = nil
        cachedIdentity = nil
        return try currentIdentity()
    }

    /// Verifies a signature against a payload and raw public key bytes.
    ///
    /// - Returns: `true` when the signature is valid.
    /// - Parameters:
    ///   - signature: DER-encoded ECDSA signature.
    ///   - payload: Canonical payload bytes originally signed.
    ///   - publicKey: Uncompressed ANSI X9.63 P-256 signing public key bytes.
    /// - Returns: `true` when the signature is valid for the payload.
    public nonisolated static func verify(signature: Data, payload: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(parsed, for: payload)
    }

    /// Computes a stable key identifier from the provided public key.
    ///
    /// - Parameter publicKey: Uncompressed ANSI X9.63 public key bytes.
    /// - Returns: Lowercase hexadecimal SHA-256 digest of canonical X9.63 bytes.
    public nonisolated static func keyID(for publicKey: Data) -> String {
        let canonicalPublicKey = canonicalizedPublicKeyData(publicKey)
        let digest = SHA256.hash(data: canonicalPublicKey)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    private nonisolated static func canonicalizedPublicKeyData(_ publicKey: Data) -> Data {
        guard let parsed = try? P256.Signing.PublicKey(x963Representation: publicKey) else {
            var invalidSentinel = Data("invalid-p256-x963:".utf8)
            invalidSentinel.append(publicKey)
            return invalidSentinel
        }
        return parsed.x963Representation
    }

    // MARK: - Key Storage

    private static func makeDefaultKeyStorage(
        service: String,
        account: String,
        synchronizable: Bool,
        fallbackToNonSynchronizableStorage: Bool,
        storage: LoomIdentityStorage
    ) -> any LoomIdentityKeyStorage {
        if storage == .memory {
            return LoomMemoryIdentityKeyStorage()
        }

        #if canImport(Security)
        return LoomKeychainIdentityKeyStorage(
            service: service,
            account: account,
            synchronizable: synchronizable,
            fallbackToNonSynchronizableStorage: fallbackToNonSynchronizableStorage
        )
        #elseif os(Windows)
        return LoomPlatformProtectedIdentityKeyStorage(service: service, account: account)
        #else
        return LoomUnavailableIdentityKeyStorage()
        #endif
    }

    private func loadOrCreatePrivateKey() throws -> P256.Signing.PrivateKey {
        if let cachedPrivateKey { return cachedPrivateKey }

        if let existingData = try keyStorage.loadPrivateKey() {
            do {
                let existing = try P256.Signing.PrivateKey(rawRepresentation: existingData)
                cachedPrivateKey = existing
                return existing
            } catch {
                throw LoomIdentityError.invalidKeyData
            }
        }

        let created = P256.Signing.PrivateKey()
        try keyStorage.storePrivateKey(created.rawRepresentation)
        cachedPrivateKey = created
        return created
    }

    nonisolated static func shouldFallbackToNonSynchronizableStorage(
        synchronizable: Bool,
        fallbackEnabled: Bool,
        error: Error
    ) -> Bool {
        guard synchronizable, fallbackEnabled else { return false }
        return keychainWriteStatus(from: error) != nil
    }

    nonisolated static func keychainWriteStatus(from error: Error) -> Int32? {
        guard let identityError = error as? LoomIdentityError else { return nil }
        guard case let .keychainWriteFailed(status) = identityError else { return nil }
        return status
    }
}

private struct LoomUnavailableIdentityKeyStorage: LoomIdentityKeyStorage {
    func loadPrivateKey() throws -> Data? {
        throw LoomIdentityKeyStorageError.persistenceFailed(
            code: 50,
            detail: "No protected identity storage backend is available."
        )
    }

    func storePrivateKey(_ privateKey: Data) throws {
        throw LoomIdentityKeyStorageError.persistenceFailed(
            code: 50,
            detail: "No protected identity storage backend is available."
        )
    }

    func deletePrivateKey() throws {
        throw LoomIdentityKeyStorageError.persistenceFailed(
            code: 50,
            detail: "No protected identity storage backend is available."
        )
    }
}

/// Identity manager failures.
public enum LoomIdentityError: LocalizedError, Sendable {
    case keychainReadFailed(status: Int32)
    case keychainWriteFailed(status: Int32)
    case keychainDeleteFailed(status: Int32)
    case invalidKeyData

    /// Human-readable error text for diagnostics and user-visible failures.
    public var errorDescription: String? {
        switch self {
        case let .keychainReadFailed(status):
            "Failed to read identity key from Keychain (status: \(status))"
        case let .keychainWriteFailed(status):
            "Failed to write identity key to Keychain (status: \(status))"
        case let .keychainDeleteFailed(status):
            "Failed to delete identity key from Keychain (status: \(status))"
        case .invalidKeyData:
            "Identity key data is invalid"
        }
    }
}
