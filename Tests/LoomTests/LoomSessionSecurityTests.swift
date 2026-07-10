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
}

private struct LoomSessionSecurityContextPair {
    let initiator: LoomSessionSecurityContext
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
        receiver: LoomSessionSecurityContext(
            role: .receiver,
            localHello: receiverHello.hello,
            remoteHello: initiatorHello.hello,
            localEphemeralPrivateKey: receiverHello.ephemeralPrivateKey,
            cipherMode: cipherMode
        )
    )
}
