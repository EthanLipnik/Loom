//
//  LoomSessionSecurity.swift
//  Loom
//
//  Created by Codex on 3/10/26.
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

    private var nextControlSendSequence: UInt64 = 0
    private var nextControlReceiveSequence: UInt64 = 0
    private var nextDataSendSequence: UInt64 = 0
    private var nextDataReceiveSequence: UInt64 = 0

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

    package mutating func seal(
        _ plaintext: Data,
        trafficClass: LoomSessionTrafficClass
    ) throws -> Data {
        let (key, sequence) = nextSendKeyAndSequence(for: trafficClass)
        let nonce = try Self.nonce(sequence: sequence)
        let aad = Data([trafficClass.rawValue])
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: aad
        )
        return sealed.ciphertext + sealed.tag
    }

    package mutating func open(
        _ ciphertextAndTag: Data,
        trafficClass: LoomSessionTrafficClass
    ) throws -> Data {
        let authTagLength = 16
        guard ciphertextAndTag.count >= authTagLength else {
            throw LoomSessionSecurityError.decryptFailed
        }

        let (key, sequence) = nextReceiveKeyAndSequence(for: trafficClass)
        let nonce = try Self.nonce(sequence: sequence)
        let ciphertext = ciphertextAndTag.dropLast(authTagLength)
        let tag = ciphertextAndTag.suffix(authTagLength)

        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        do {
            return try ChaChaPoly.open(
                box,
                using: key,
                authenticating: Data([trafficClass.rawValue])
            )
        } catch {
            throw LoomSessionSecurityError.decryptFailed
        }
    }

    private mutating func nextSendKeyAndSequence(
        for trafficClass: LoomSessionTrafficClass
    ) -> (SymmetricKey, UInt64) {
        switch trafficClass {
        case .control:
            defer { nextControlSendSequence &+= 1 }
            return (controlSendKey, nextControlSendSequence)
        case .data:
            defer { nextDataSendSequence &+= 1 }
            return (dataSendKey, nextDataSendSequence)
        }
    }

    private mutating func nextReceiveKeyAndSequence(
        for trafficClass: LoomSessionTrafficClass
    ) -> (SymmetricKey, UInt64) {
        switch trafficClass {
        case .control:
            defer { nextControlReceiveSequence &+= 1 }
            return (controlReceiveKey, nextControlReceiveSequence)
        case .data:
            defer { nextDataReceiveSequence &+= 1 }
            return (dataReceiveKey, nextDataReceiveSequence)
        }
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

    private static func nonce(sequence: UInt64) throws -> ChaChaPoly.Nonce {
        var nonceData = Data(repeating: 0, count: 12)
        var beSequence = sequence.bigEndian
        withUnsafeBytes(of: &beSequence) { bytes in
            nonceData.replaceSubrange(4..<12, with: bytes)
        }
        return try ChaChaPoly.Nonce(data: nonceData)
    }
}

private struct LoomSessionTranscript: Codable {
    let initiatorHello: LoomSessionHello
    let receiverHello: LoomSessionHello
}
