//
//  LoomSessionSecurityTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Session Security")
struct LoomSessionSecurityTests {
    @MainActor
    @Test("Session envelopes preserve wire length and traffic-class AAD")
    func sessionEnvelopesPreserveWireLengthAndAAD() throws {
        let initiatorIdentityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.session-security.\(UUID().uuidString)",
            account: "initiator",
            synchronizable: false
        )
        let receiverIdentityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.session-security.\(UUID().uuidString)",
            account: "receiver",
            synchronizable: false
        )
        let initiatorPreparedHello = try LoomSessionHelloValidator.makePreparedSignedHello(
            from: LoomSessionHelloRequest(
                deviceID: UUID(),
                deviceName: "Initiator",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement()
            ),
            identityManager: initiatorIdentityManager
        )
        let receiverPreparedHello = try LoomSessionHelloValidator.makePreparedSignedHello(
            from: LoomSessionHelloRequest(
                deviceID: UUID(),
                deviceName: "Receiver",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement()
            ),
            identityManager: receiverIdentityManager
        )

        let initiatorContext = try LoomSessionSecurityContext(
            role: .initiator,
            localHello: initiatorPreparedHello.hello,
            remoteHello: receiverPreparedHello.hello,
            localEphemeralPrivateKey: initiatorPreparedHello.ephemeralPrivateKey
        )
        let receiverContext = try LoomSessionSecurityContext(
            role: .receiver,
            localHello: receiverPreparedHello.hello,
            remoteHello: initiatorPreparedHello.hello,
            localEphemeralPrivateKey: receiverPreparedHello.ephemeralPrivateKey
        )
        let plaintext = Data("hello encrypted loom".utf8)

        let encrypted = try initiatorContext.seal(plaintext, trafficClass: .control)
        let decrypted = try receiverContext.open(encrypted, trafficClass: .control)

        #expect(decrypted == plaintext)
        #expect(encrypted.count == plaintext.count + 12 + 16)
        #expect(throws: LoomSessionSecurityError.self) {
            _ = try receiverContext.open(encrypted, trafficClass: .data)
        }
    }

    @MainActor
    @Test("Sequenced session encryption rejects replay without consuming unauthenticated sequences")
    func sequencedSessionEncryptionRejectsReplay() throws {
        let contexts = try makeSessionSecurityContexts(cipherMode: .sequencedV2)
        let plaintext = Data("sequence protected".utf8)
        let encrypted = try contexts.initiator.seal(plaintext, trafficClass: .data)

        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 0xff
        #expect(throws: LoomSessionSecurityError.decryptFailed) {
            _ = try contexts.receiver.open(tampered, trafficClass: .data)
        }
        #expect(try contexts.receiver.open(encrypted, trafficClass: .data) == plaintext)
        #expect(throws: LoomSessionSecurityError.replayDetected) {
            _ = try contexts.receiver.open(encrypted, trafficClass: .data)
        }
        #expect(encrypted.count == plaintext.count + 8 + 16)
    }

    @MainActor
    @Test("Sequenced session encryption accepts bounded out-of-order delivery")
    func sequencedSessionEncryptionAcceptsOutOfOrderDelivery() throws {
        let contexts = try makeSessionSecurityContexts(cipherMode: .sequencedV2)
        let first = try contexts.initiator.seal(Data([1]), trafficClass: .data)
        let second = try contexts.initiator.seal(Data([2]), trafficClass: .data)

        #expect(try contexts.receiver.open(second, trafficClass: .data) == Data([2]))
        #expect(try contexts.receiver.open(first, trafficClass: .data) == Data([1]))
    }

    @MainActor
    @Test("Sequenced batch sealing preserves sequential wire bytes and nonce order")
    func sequencedBatchSealingPreservesSequentialWireBytes() throws {
        let contexts = try makeSessionSecurityContexts(cipherMode: .sequencedV2)
        let plaintexts = (0 ..< 120).map { index in
            var payload = Data(repeating: UInt8(truncatingIfNeeded: index), count: 1_200)
            let value = UInt32(index)
            payload.append(UInt8(truncatingIfNeeded: value))
            payload.append(UInt8(truncatingIfNeeded: value >> 8))
            payload.append(UInt8(truncatingIfNeeded: value >> 16))
            payload.append(UInt8(truncatingIfNeeded: value >> 24))
            return payload
        }

        let batchCiphertexts = try contexts.initiator.sealBatch(
            plaintexts,
            trafficClass: .data
        )
        let sequentialCiphertexts = try plaintexts.map {
            try contexts.comparisonInitiator.seal($0, trafficClass: .data)
        }

        #expect(batchCiphertexts == sequentialCiphertexts)
        #expect(batchCiphertexts.count == plaintexts.count)
        #expect(batchCiphertexts.enumerated().allSatisfy { index, ciphertext in
            decodedSequence(from: ciphertext) == UInt64(index)
        })
        for (ciphertext, plaintext) in zip(batchCiphertexts, plaintexts) {
            #expect(try contexts.receiver.open(ciphertext, trafficClass: .data) == plaintext)
        }
        let nextCiphertext = try contexts.initiator.seal(Data([0xff]), trafficClass: .data)
        #expect(decodedSequence(from: nextCiphertext) == UInt64(plaintexts.count))
    }
}

private struct LoomSessionSecurityContextPair {
    let initiator: LoomSessionSecurityContext
    let comparisonInitiator: LoomSessionSecurityContext
    let receiver: LoomSessionSecurityContext
}

@MainActor
private func makeSessionSecurityContexts(
    cipherMode: LoomSessionCipherMode
) throws -> LoomSessionSecurityContextPair {
    let initiatorIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.session-security-v2.\(UUID().uuidString)",
        account: "initiator",
        synchronizable: false
    )
    let receiverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.session-security-v2.\(UUID().uuidString)",
        account: "receiver",
        synchronizable: false
    )
    let initiatorHello = try LoomSessionHelloValidator.makePreparedSignedHello(
        from: LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Initiator",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement()
        ),
        identityManager: initiatorIdentityManager
    )
    let receiverHello = try LoomSessionHelloValidator.makePreparedSignedHello(
        from: LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Receiver",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement()
        ),
        identityManager: receiverIdentityManager
    )

    return try LoomSessionSecurityContextPair(
        initiator: LoomSessionSecurityContext(
            role: .initiator,
            localHello: initiatorHello.hello,
            remoteHello: receiverHello.hello,
            localEphemeralPrivateKey: initiatorHello.ephemeralPrivateKey,
            cipherMode: cipherMode
        ),
        comparisonInitiator: LoomSessionSecurityContext(
            role: .initiator,
            localHello: initiatorHello.hello,
            remoteHello: receiverHello.hello,
            localEphemeralPrivateKey: initiatorHello.ephemeralPrivateKey,
            cipherMode: cipherMode
        ),
        receiver: LoomSessionSecurityContext(
            role: .receiver,
            localHello: receiverHello.hello,
            remoteHello: initiatorHello.hello,
            localEphemeralPrivateKey: receiverHello.ephemeralPrivateKey,
            cipherMode: cipherMode
        )
    )
}

private func decodedSequence(from ciphertext: Data) -> UInt64? {
    guard ciphertext.count >= MemoryLayout<UInt64>.size else { return nil }
    return ciphertext.prefix(MemoryLayout<UInt64>.size).reduce(UInt64(0)) { partial, byte in
        (partial << 8) | UInt64(byte)
    }
}
