//
//  LoomSessionHelloTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Session Hello")
struct LoomSessionHelloTests {
    @Test("Unknown device types decode as the semantic unknown case")
    func unknownDeviceTypeDecodesAsUnknown() throws {
        let decoded = try JSONDecoder().decode(DeviceType.self, from: Data(#""future-device""#.utf8))

        #expect(decoded == .unknown)
        #expect(try JSONEncoder().encode(decoded) == Data(#""unknown""#.utf8))
    }

    @MainActor
    @Test("Signed hello validates into an authenticated peer identity")
    func signedHelloValidates() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.session-hello.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let request = LoomSessionHelloRequest(
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            deviceName: "Test Mac",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                deviceType: .mac
            ),
            supportedFeatures: ["loom.streams.v1"],
            iCloudUserID: "user-1"
        )

        let hello = try LoomSessionHelloValidator.makeSignedHello(
            from: request,
            identityManager: identityManager
        )
        let validator = LoomSessionHelloValidator()
        let peerIdentity = try await validator.validate(
            hello,
            endpointDescription: "127.0.0.1:9999"
        )

        #expect(peerIdentity.deviceID == request.deviceID)
        #expect(peerIdentity.name == request.deviceName)
        #expect(peerIdentity.deviceType == request.deviceType)
        #expect(peerIdentity.iCloudUserID == "user-1")
        #expect(peerIdentity.isIdentityAuthenticated)
    }

    @MainActor
    @Test("Hello validation rejects replayed nonces")
    func helloRejectsReplay() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.session-replay.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let request = LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Replay Test",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement()
        )
        let hello = try LoomSessionHelloValidator.makeSignedHello(
            from: request,
            identityManager: identityManager
        )
        let validator = LoomSessionHelloValidator()

        _ = try await validator.validate(hello, endpointDescription: "127.0.0.1:1")
        await #expect(throws: LoomSessionHelloError.replayRejected) {
            try await validator.validate(hello, endpointDescription: "127.0.0.1:2")
        }
    }

    @MainActor
    @Test("Fresh default validators share replay state across sessions")
    func defaultValidatorsRejectCrossSessionReplay() async throws {
        let identityManager = LoomIdentityManager.inMemory()
        let hello = try LoomSessionHelloValidator.makeSignedHello(
            from: LoomSessionHelloRequest(
                deviceID: UUID(),
                deviceName: "Cross-session Replay Test",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement()
            ),
            identityManager: identityManager
        )

        _ = try await LoomSessionHelloValidator().validate(
            hello,
            endpointDescription: "127.0.0.1:1"
        )
        await #expect(throws: LoomSessionHelloError.replayRejected) {
            try await LoomSessionHelloValidator().validate(
                hello,
                endpointDescription: "127.0.0.1:2"
            )
        }
    }

    @MainActor
    @Test("Signed hellos preserve and validate unknown device-type spellings")
    func signedHelloPreservesUnknownDeviceTypeSpellings() async throws {
        let rootDeviceTypeRawValue = "future-client"
        let advertisementDeviceTypeRawValue = "future-client-advertisement"
        let identityManager = LoomIdentityManager.inMemory()
        let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let baseHello = try LoomSessionHelloValidator.makeSignedHello(
            from: LoomSessionHelloRequest(
                deviceID: deviceID,
                deviceName: "Future Device",
                deviceType: .unknown,
                advertisement: LoomPeerAdvertisement(
                    deviceID: deviceID,
                    deviceType: .unknown,
                    metadata: ["example.platform": "future"]
                ),
                supportedFeatures: ["loom.streams.v1"],
                iCloudUserID: "future-user"
            ),
            identityManager: identityManager
        )

        var helloObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseHello)) as? [String: Any]
        )
        helloObject["deviceType"] = rootDeviceTypeRawValue
        var advertisementObject = try #require(helloObject["advertisement"] as? [String: Any])
        advertisementObject["deviceType"] = advertisementDeviceTypeRawValue
        helloObject["advertisement"] = advertisementObject

        let unsignedData = try JSONSerialization.data(withJSONObject: helloObject)
        let unsignedHello = try JSONDecoder().decode(LoomSessionHello.self, from: unsignedData)
        #expect(unsignedHello.deviceType == .unknown)
        #expect(unsignedHello.advertisement.deviceType == .unknown)

        let canonicalPayload = UnknownDeviceTypeCanonicalHelloPayload(
            deviceID: unsignedHello.deviceID,
            deviceName: unsignedHello.deviceName,
            deviceType: rootDeviceTypeRawValue,
            protocolVersion: unsignedHello.protocolVersion,
            advertisement: unsignedHello.advertisement,
            supportedFeatures: unsignedHello.supportedFeatures.sorted(),
            iCloudUserID: unsignedHello.iCloudUserID,
            keyID: unsignedHello.identity.keyID,
            publicKey: unsignedHello.identity.publicKey,
            ephemeralPublicKey: unsignedHello.identity.ephemeralPublicKey,
            timestampMs: unsignedHello.identity.timestampMs,
            nonce: unsignedHello.identity.nonce
        )
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try identityManager.sign(canonicalEncoder.encode(canonicalPayload))
        var identityObject = try #require(helloObject["identity"] as? [String: Any])
        identityObject["signature"] = signature.base64EncodedString()
        helloObject["identity"] = identityObject

        let signedData = try JSONSerialization.data(withJSONObject: helloObject)
        let signedHello = try JSONDecoder().decode(LoomSessionHello.self, from: signedData)
        let reencodedObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(signedHello)) as? [String: Any]
        )
        let reencodedAdvertisement = try #require(reencodedObject["advertisement"] as? [String: Any])
        #expect(reencodedObject["deviceType"] as? String == rootDeviceTypeRawValue)
        #expect(reencodedAdvertisement["deviceType"] as? String == advertisementDeviceTypeRawValue)

        let txtRecord = signedHello.advertisement.toTXTRecord()
        #expect(txtRecord["dt"] == advertisementDeviceTypeRawValue)
        let txtDecodedAdvertisement = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        #expect(txtDecodedAdvertisement.deviceType == .unknown)
        #expect(txtDecodedAdvertisement.toTXTRecord()["dt"] == advertisementDeviceTypeRawValue)

        let peerIdentity = try await LoomSessionHelloValidator().validate(
            signedHello,
            endpointDescription: "127.0.0.1:9999"
        )
        #expect(peerIdentity.deviceID == deviceID)
        #expect(peerIdentity.deviceType == .unknown)
        #expect(peerIdentity.advertisementMetadata["example.platform"] == "future")
    }
}

private struct UnknownDeviceTypeCanonicalHelloPayload: Encodable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: String
    let protocolVersion: Int
    let advertisement: LoomPeerAdvertisement
    let supportedFeatures: [String]
    let iCloudUserID: String?
    let keyID: String
    let publicKey: Data
    let ephemeralPublicKey: Data
    let timestampMs: Int64
    let nonce: String
}
