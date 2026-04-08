//
//  LoomSessionSecurity.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CryptoKit
import Foundation

package enum LoomSessionTrafficClass: UInt8, Sendable {
    case control = 1
    case data = 2
}

package enum LoomSessionSecurityError: LocalizedError, Sendable {
    case invalidRemoteEphemeralKey
    case decryptFailed

    package var errorDescription: String? {
        switch self {
        case .invalidRemoteEphemeralKey:
            "The peer presented an invalid ephemeral session key."
        case .decryptFailed:
            "Failed to decrypt the Loom session payload."
        }
    }
}

package struct LoomSessionSecurityContext: Sendable {
    private let controlSendKey: SymmetricKey
    private let controlReceiveKey: SymmetricKey
    private let dataSendKey: SymmetricKey
    private let dataReceiveKey: SymmetricKey

    private static let nonceSize = 12
    private static let authTagSize = 16

    package init(
        role: LoomSessionRole,
        localHello: LoomSessionHello,
        remoteHello: LoomSessionHello,
        localEphemeralPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws {
        let remoteEphemeralKey: P256.KeyAgreement.PublicKey
        do {
            remoteEphemeralKey = try P256.KeyAgreement.PublicKey(
                x963Representation: remoteHello.identity.ephemeralPublicKey
            )
        } catch {
            throw LoomSessionSecurityError.invalidRemoteEphemeralKey
        }

        let sharedSecret = try localEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: remoteEphemeralKey)
        let transcript = try Self.transcript(
            role: role,
            localHello: localHello,
            remoteHello: remoteHello
        )
        let salt = Data(SHA256.hash(data: transcript))

        controlSendKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator ? "loom-session-control-initiator-v1" : "loom-session-control-receiver-v1"
        )
        controlReceiveKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator ? "loom-session-control-receiver-v1" : "loom-session-control-initiator-v1"
        )
        dataSendKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator ? "loom-session-data-initiator-v1" : "loom-session-data-receiver-v1"
        )
        dataReceiveKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator ? "loom-session-data-receiver-v1" : "loom-session-data-initiator-v1"
        )
    }

    /// Encrypt plaintext with a random nonce.
    /// Returns `[nonce: 12][ciphertext][tag: 16]`.
    package func seal(
        _ plaintext: Data,
        trafficClass: LoomSessionTrafficClass
    ) throws -> Data {
        let key = sendKey(for: trafficClass)
        let nonce = try AES.GCM.Nonce(data: Self.randomNonce())
        let aad = Data([trafficClass.rawValue])
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: aad
        )
        return Data(nonce) + sealed.ciphertext + sealed.tag
    }

    /// Decrypt payload of the form `[nonce: 12][ciphertext][tag: 16]`.
    package func open(
        _ nonceAndCiphertextAndTag: Data,
        trafficClass: LoomSessionTrafficClass
    ) throws -> Data {
        guard nonceAndCiphertextAndTag.count >= Self.nonceSize + Self.authTagSize else {
            throw LoomSessionSecurityError.decryptFailed
        }

        let key = receiveKey(for: trafficClass)
        let nonceData = nonceAndCiphertextAndTag.prefix(Self.nonceSize)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let rest = nonceAndCiphertextAndTag.dropFirst(Self.nonceSize)
        let ciphertext = rest.dropLast(Self.authTagSize)
        let tag = rest.suffix(Self.authTagSize)

        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        do {
            return try AES.GCM.open(
                box,
                using: key,
                authenticating: Data([trafficClass.rawValue])
            )
        } catch {
            throw LoomSessionSecurityError.decryptFailed
        }
    }

    private func sendKey(for trafficClass: LoomSessionTrafficClass) -> SymmetricKey {
        switch trafficClass {
        case .control: controlSendKey
        case .data: dataSendKey
        }
    }

    private func receiveKey(for trafficClass: LoomSessionTrafficClass) -> SymmetricKey {
        switch trafficClass {
        case .control: controlReceiveKey
        case .data: dataReceiveKey
        }
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceSize)
        for i in bytes.indices {
            bytes[i] = .random(in: .min ... .max)
        }
        return Data(bytes)
    }

    private static func deriveKey(
        sharedSecret: SharedSecret,
        salt: Data,
        label: String
    ) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(label.utf8),
            outputByteCount: 32
        )
    }

    private static func transcript(
        role: LoomSessionRole,
        localHello: LoomSessionHello,
        remoteHello: LoomSessionHello
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let initiatorHello = role == .initiator ? localHello : remoteHello
        let receiverHello = role == .initiator ? remoteHello : localHello
        return try encoder.encode(
            LoomSessionTranscript(
                initiatorHello: initiatorHello,
                receiverHello: receiverHello
            )
        )
    }
}

private struct LoomSessionTranscript: Codable {
    let initiatorHello: LoomSessionHello
    let receiverHello: LoomSessionHello
}
