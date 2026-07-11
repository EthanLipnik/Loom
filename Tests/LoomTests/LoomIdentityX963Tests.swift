//
//  LoomIdentityX963Tests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Regression coverage for canonical X9.63 identity keys.
//

import CryptoKit
import Foundation
@testable import Loom
import Testing

@Suite("Loom Identity X9.63")
struct LoomIdentityX963Tests {
    @MainActor
    @Test("Current identity uses uncompressed X9.63 public key bytes")
    func currentIdentityUsesX963PublicKey() throws {
        let manager = makeIdentityManager()
        let identity = try manager.currentIdentity()

        #expect(identity.publicKey.count == 65)
        #expect(identity.publicKey.first == 0x04)
    }

    @MainActor
    @Test("Key IDs hash canonical X9.63 bytes")
    func keyIDUsesCanonicalX963Bytes() throws {
        let manager = makeIdentityManager()
        let identity = try manager.currentIdentity()

        let expected = sha256Hex(identity.publicKey)
        #expect(identity.keyID == expected)
        #expect(LoomIdentityManager.keyID(for: identity.publicKey) == expected)
    }

    @MainActor
    @Test("Signature verification accepts X9.63 and rejects legacy raw format")
    func signatureVerificationRequiresX963PublicKey() throws {
        let manager = makeIdentityManager()
        let payload = Data("loom-signature-check".utf8)
        let signature = try manager.sign(payload)
        let identity = try manager.currentIdentity()

        #expect(LoomIdentityManager.verify(
            signature: signature,
            payload: payload,
            publicKey: identity.publicKey
        ))

        let legacyRawPublicKey = Data(identity.publicKey.dropFirst())
        #expect(!LoomIdentityManager.verify(
            signature: signature,
            payload: payload,
            publicKey: legacyRawPublicKey
        ))
    }

    @MainActor
    @Test("ECDH derivation accepts X9.63 peer public keys")
    func deriveSharedKeyAcceptsX963PeerPublicKey() throws {
        let manager = makeIdentityManager()
        let peerKey = P256.KeyAgreement.PrivateKey()
        let salt = Data("loom-salt".utf8)
        let sharedInfo = Data("loom-shared-info".utf8)

        let derivedKey = try manager.deriveSharedKey(
            with: peerKey.publicKey.x963Representation,
            salt: salt,
            sharedInfo: sharedInfo
        )
        #expect(derivedKey.count == 32)

        do {
            _ = try manager.deriveSharedKey(
                with: peerKey.publicKey.rawRepresentation,
                salt: salt,
                sharedInfo: sharedInfo
            )
            Issue.record("Expected non-X9.63 peer key derivation to fail.")
        } catch {
            // Expected invalid key encoding.
        }
    }

    @Test("Synchronizable write failures can fall back to local storage when enabled")
    func synchronizableWriteFailuresCanFallbackToLocalStorage() {
        let error = LoomIdentityError.keychainWriteFailed(status: errSecMissingEntitlement)

        #expect(LoomIdentityManager.shouldFallbackToNonSynchronizableStorage(
            synchronizable: true,
            fallbackEnabled: true,
            error: error
        ))
        #expect(LoomIdentityManager.keychainWriteStatus(from: error) == errSecMissingEntitlement)
    }

    @Test("Identity fallback stays disabled for non-write failures")
    func identityFallbackStaysDisabledForNonWriteFailures() {
        #expect(!LoomIdentityManager.shouldFallbackToNonSynchronizableStorage(
            synchronizable: true,
            fallbackEnabled: true,
            error: LoomIdentityError.keychainReadFailed(status: errSecInteractionNotAllowed)
        ))
        #expect(!LoomIdentityManager.shouldFallbackToNonSynchronizableStorage(
            synchronizable: true,
            fallbackEnabled: false,
            error: LoomIdentityError.keychainWriteFailed(status: errSecMissingEntitlement)
        ))
        #expect(!LoomIdentityManager.shouldFallbackToNonSynchronizableStorage(
            synchronizable: false,
            fallbackEnabled: true,
            error: LoomIdentityError.keychainWriteFailed(status: errSecMissingEntitlement)
        ))
    }

    @MainActor
    @Test("In-memory identity manager keeps identity process-local")
    func inMemoryIdentityManagerKeepsIdentityProcessLocal() throws {
        let firstManager = LoomIdentityManager.inMemory()
        let secondManager = LoomIdentityManager.inMemory()

        let firstIdentity = try firstManager.currentIdentity()
        let repeatedIdentity = try firstManager.currentIdentity()
        let secondIdentity = try secondManager.currentIdentity()

        #expect(firstIdentity == repeatedIdentity)
        #expect(firstIdentity != secondIdentity)
    }

    @MainActor
    @Test("In-memory identity manager signs and rotates without persistent storage")
    func inMemoryIdentityManagerSignsAndRotatesWithoutPersistentStorage() throws {
        let manager = LoomIdentityManager.inMemory()
        let payload = Data("loom-in-memory-identity".utf8)

        let firstIdentity = try manager.currentIdentity()
        let signature = try manager.sign(payload)

        #expect(LoomIdentityManager.verify(
            signature: signature,
            payload: payload,
            publicKey: firstIdentity.publicKey
        ))

        let rotatedIdentity = try manager.rotateIdentity()

        #expect(rotatedIdentity != firstIdentity)
        #expect(try manager.currentIdentity() == rotatedIdentity)
    }

    @MainActor
    @Test("Unreadable protected identity storage fails without regenerating a key")
    func unreadableStorageFailsClosed() {
        let manager = LoomIdentityManager(
            service: "com.loom.tests.identity.unreadable",
            account: "p256-signing",
            synchronizable: false,
            fallbackToNonSynchronizableStorage: false,
            storage: .keychain,
            identityKeyStorage: UnreadableIdentityKeyStorage()
        )

        #expect(throws: LoomIdentityKeyStorageError.self) {
            _ = try manager.currentIdentity()
        }
    }

    @MainActor
    private func makeIdentityManager() -> LoomIdentityManager {
        LoomIdentityManager(
            service: "com.loom.tests.identity.\(UUID().uuidString)",
            account: "p256-signing-\(UUID().uuidString)",
            synchronizable: false
        )
    }

    private func sha256Hex(_ value: Data) -> String {
        let digest = SHA256.hash(data: value)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }
}

private struct UnreadableIdentityKeyStorage: LoomIdentityKeyStorage {
    func loadPrivateKey() throws -> Data? {
        throw LoomIdentityKeyStorageError.unreadable(
            code: 13,
            detail: "Synthetic protected-file failure."
        )
    }

    func storePrivateKey(_ privateKey: Data) throws {
        Issue.record("Identity manager must not replace an unreadable protected key.")
    }

    func deletePrivateKey() throws {}
}
