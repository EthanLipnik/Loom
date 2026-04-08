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
}
