//
//  LoomSessionSecurity.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

package enum LoomSessionTrafficClass: UInt8, Sendable, Hashable {
    case control = 1
    case data = 2
    case priorityInput = 3
    case keyConfirmation = 4
}

package enum LoomSessionSecurityError: LocalizedError, Sendable {
    case invalidRemoteEphemeralKey
    case decryptFailed
    case replayDetected
    case sequenceExhausted

    package var errorDescription: String? {
        switch self {
        case .invalidRemoteEphemeralKey:
            "The peer presented an invalid ephemeral session key."
        case .decryptFailed:
            "Failed to decrypt the Loom session payload."
        case .replayDetected:
            "The encrypted Loom session payload was already received."
        case .sequenceExhausted:
            "The encrypted Loom session sequence space is exhausted."
        }
    }
}

package enum LoomSessionCipherMode: Sendable, Equatable {
    case legacyRandomNonce
    case sequencedV2
}

private final class LoomSessionCipherState: @unchecked Sendable {
    private struct ReceiveWindow {
        var highestSequence: UInt64?
        var acceptedSequences: Set<UInt64> = []
    }

    private let lock = NSLock()
    private var nextSendSequenceByTrafficClass: [LoomSessionTrafficClass: UInt64] = [:]
    private var receiveWindowByTrafficClass: [LoomSessionTrafficClass: ReceiveWindow] = [:]
    private static let maximumReorderingWindow: UInt64 = 4_096

    func nextSendSequence(for trafficClass: LoomSessionTrafficClass) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSendSequenceByTrafficClass[trafficClass] ?? 0
        guard sequence < UInt64.max else {
            throw LoomSessionSecurityError.sequenceExhausted
        }
        nextSendSequenceByTrafficClass[trafficClass] = sequence + 1
        return sequence
    }

    func recordReceivedSequence(_ sequence: UInt64, for trafficClass: LoomSessionTrafficClass) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var window = receiveWindowByTrafficClass[trafficClass] ?? ReceiveWindow()
        if window.acceptedSequences.contains(sequence) {
            return false
        }
        if let highestSequence = window.highestSequence,
           highestSequence >= Self.maximumReorderingWindow,
           sequence <= highestSequence - Self.maximumReorderingWindow {
            return false
        }

        window.acceptedSequences.insert(sequence)
        window.highestSequence = max(window.highestSequence ?? sequence, sequence)
        if let highestSequence = window.highestSequence,
           highestSequence >= Self.maximumReorderingWindow {
            let minimumSequence = highestSequence - Self.maximumReorderingWindow + 1
            window.acceptedSequences = window.acceptedSequences.filter { $0 >= minimumSequence }
        }
        receiveWindowByTrafficClass[trafficClass] = window
        return true
    }
}

package struct LoomSessionSecurityContext: Sendable {
    private let controlSendKey: SymmetricKey
    private let controlReceiveKey: SymmetricKey
    private let dataSendKey: SymmetricKey
    private let dataReceiveKey: SymmetricKey
    private let priorityInputSendKey: SymmetricKey
    private let priorityInputReceiveKey: SymmetricKey
    private let keyConfirmationSendKey: SymmetricKey
    private let keyConfirmationReceiveKey: SymmetricKey
    private let cipherMode: LoomSessionCipherMode
    private let cipherState = LoomSessionCipherState()

    private static let nonceSize = 12
    private static let authTagSize = 16

    package init(
        role: LoomSessionRole,
        localHello: LoomSessionHello,
        remoteHello: LoomSessionHello,
        localEphemeralPrivateKey: P256.KeyAgreement.PrivateKey,
        cipherMode: LoomSessionCipherMode = .legacyRandomNonce
    ) throws {
        self.cipherMode = cipherMode
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
        priorityInputSendKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator
                ? "loom-session-priority-input-initiator-v1"
                : "loom-session-priority-input-receiver-v1"
        )
        priorityInputReceiveKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator
                ? "loom-session-priority-input-receiver-v1"
                : "loom-session-priority-input-initiator-v1"
        )
        keyConfirmationSendKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator
                ? "loom-session-key-confirmation-initiator-v2"
                : "loom-session-key-confirmation-receiver-v2"
        )
        keyConfirmationReceiveKey = Self.deriveKey(
            sharedSecret: sharedSecret,
            salt: salt,
            label: role == .initiator
                ? "loom-session-key-confirmation-receiver-v2"
                : "loom-session-key-confirmation-initiator-v2"
        )
    }

    /// Encrypt plaintext using the negotiated cipher mode.
    /// Legacy mode returns `[nonce: 12][ciphertext][tag: 16]`; sequenced v2
    /// returns `[sequence: 8][ciphertext][tag: 16]`.
    package func seal(
        _ plaintext: Data,
        trafficClass: LoomSessionTrafficClass
    ) throws -> Data {
        let key = sendKey(for: trafficClass)
        let nonceData: Data
        let sequence: UInt64?
        switch cipherMode {
        case .legacyRandomNonce:
            nonceData = Self.randomNonce()
            sequence = nil
        case .sequencedV2:
            let nextSequence = try cipherState.nextSendSequence(for: trafficClass)
            nonceData = Self.nonce(for: nextSequence)
            sequence = nextSequence
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let aad = Data([trafficClass.rawValue])
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: aad
        )
        if let sequence {
            return Self.encode(sequence: sequence) + sealed.ciphertext + sealed.tag
        }
        return Data(nonce) + sealed.ciphertext + sealed.tag
    }

    /// Decrypt a payload in the negotiated cipher mode and reject sequenced-v2 replays.
    package func open(
        _ nonceAndCiphertextAndTag: Data,
        trafficClass: LoomSessionTrafficClass
    ) throws -> Data {
        let minimumHeaderSize = cipherMode == .sequencedV2 ? MemoryLayout<UInt64>.size : Self.nonceSize
        guard nonceAndCiphertextAndTag.count >= minimumHeaderSize + Self.authTagSize else {
            throw LoomSessionSecurityError.decryptFailed
        }

        let key = receiveKey(for: trafficClass)
        let sequence: UInt64?
        let headerSize: Int
        let nonceData: Data
        switch cipherMode {
        case .legacyRandomNonce:
            sequence = nil
            headerSize = Self.nonceSize
            nonceData = Data(nonceAndCiphertextAndTag.prefix(Self.nonceSize))
        case .sequencedV2:
            guard let decodedSequence = Self.decodeSequence(from: nonceAndCiphertextAndTag) else {
                throw LoomSessionSecurityError.decryptFailed
            }
            sequence = decodedSequence
            headerSize = MemoryLayout<UInt64>.size
            nonceData = Self.nonce(for: decodedSequence)
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let rest = nonceAndCiphertextAndTag.dropFirst(headerSize)
        let ciphertext = rest.dropLast(Self.authTagSize)
        let tag = rest.suffix(Self.authTagSize)

        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        do {
            let plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: Data([trafficClass.rawValue])
            )
            if let sequence,
               !cipherState.recordReceivedSequence(sequence, for: trafficClass) {
                throw LoomSessionSecurityError.replayDetected
            }
            return plaintext
        } catch let error as LoomSessionSecurityError {
            throw error
        } catch {
            throw LoomSessionSecurityError.decryptFailed
        }
    }

    private func sendKey(for trafficClass: LoomSessionTrafficClass) -> SymmetricKey {
        switch trafficClass {
        case .control: controlSendKey
        case .data: dataSendKey
        case .priorityInput: priorityInputSendKey
        case .keyConfirmation: keyConfirmationSendKey
        }
    }

    private func receiveKey(for trafficClass: LoomSessionTrafficClass) -> SymmetricKey {
        switch trafficClass {
        case .control: controlReceiveKey
        case .data: dataReceiveKey
        case .priorityInput: priorityInputReceiveKey
        case .keyConfirmation: keyConfirmationReceiveKey
        }
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceSize)
        for i in bytes.indices {
            bytes[i] = .random(in: .min ... .max)
        }
        return Data(bytes)
    }

    private static func nonce(for sequence: UInt64) -> Data {
        Data(repeating: 0, count: nonceSize - MemoryLayout<UInt64>.size) + encode(sequence: sequence)
    }

    private static func encode(sequence: UInt64) -> Data {
        var value = sequence.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func decodeSequence(from data: Data) -> UInt64? {
        guard data.count >= MemoryLayout<UInt64>.size else { return nil }
        return data.prefix(MemoryLayout<UInt64>.size).reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
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
}

private struct LoomSessionTranscript: Codable {
    let initiatorHello: LoomSessionHello
    let receiverHello: LoomSessionHello
}
