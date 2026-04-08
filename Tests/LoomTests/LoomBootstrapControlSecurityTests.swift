//
//  LoomBootstrapControlSecurityTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Bootstrap Control Security")
struct LoomBootstrapControlSecurityTests {
    @Test("Credential encryption uses AES-GCM combined payloads")
    func credentialEncryptionUsesCombinedPayload() throws {
        let credentials = LoomBootstrapCredentials(userIdentifier: "ethan", secret: "hunter2")
        let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let timestampMs: Int64 = 1_234_567_890
        let nonce = "bootstrap-nonce"

        let encrypted = try LoomBootstrapControlSecurity.encryptCredentials(
            credentials,
            sharedSecret: "shared-secret",
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let decrypted = try LoomBootstrapControlSecurity.decryptCredentials(
            encrypted,
            sharedSecret: "shared-secret",
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )

        #expect(decrypted == credentials)
        let plaintext = try JSONEncoder().encode(credentials)
        #expect(encrypted.combined.count == plaintext.count + 12 + 16)
    }
}
