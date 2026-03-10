//
//  LoomSessionHello.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import CryptoKit
import Foundation

/// Connection role used by authenticated Loom sessions.
public enum LoomSessionRole: String, Sendable, Codable {
    case initiator
    case receiver
}

/// Signed identity envelope exchanged during authenticated Loom session setup.
public struct LoomSessionHello: Codable, Sendable, Equatable {
    public struct Identity: Codable, Sendable, Equatable {
        public let keyID: String
        public let publicKey: Data
        public let ephemeralPublicKey: Data
        public let timestampMs: Int64
        public let nonce: String
        public let signature: Data

        public init(
            keyID: String,
            publicKey: Data,
            ephemeralPublicKey: Data,
            timestampMs: Int64,
            nonce: String,
            signature: Data
        ) {
            self.keyID = keyID
            self.publicKey = publicKey
            self.ephemeralPublicKey = ephemeralPublicKey
            self.timestampMs = timestampMs
            self.nonce = nonce
            self.signature = signature
        }
    }

    public let deviceID: UUID
    public let deviceName: String
    public let deviceType: DeviceType
    public let protocolVersion: Int
    public let advertisement: LoomPeerAdvertisement
    public let supportedFeatures: [String]
    public let iCloudUserID: String?
    public let identity: Identity

    public init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        protocolVersion: Int,
        advertisement: LoomPeerAdvertisement,
        supportedFeatures: [String],
        iCloudUserID: String?,
        identity: Identity
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.advertisement = advertisement
        self.supportedFeatures = supportedFeatures
        self.iCloudUserID = iCloudUserID
        self.identity = identity
    }
}

/// Immutable hello input used to create a signed session advertisement.
public struct LoomSessionHelloRequest: Sendable, Equatable {
    public let deviceID: UUID
    public let deviceName: String
    public let deviceType: DeviceType
    public let advertisement: LoomPeerAdvertisement
    public let supportedFeatures: [String]
    public let iCloudUserID: String?

    public init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        advertisement: LoomPeerAdvertisement,
        supportedFeatures: [String] = LoomSessionHelloRequest.defaultFeatures,
        iCloudUserID: String? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.advertisement = advertisement
        self.supportedFeatures = supportedFeatures
        self.iCloudUserID = iCloudUserID
    }

    public static let defaultFeatures: [String] = [
        "loom.handshake.v1",
        "loom.session-encryption.v1",
        "loom.streams.v1",
        "loom.bootstrap.v1",
    ]
}

/// Authenticated session handshake failures.
public enum LoomSessionHelloError: LocalizedError, Sendable, Equatable {
    case invalidKeyID
    case invalidSignature
    case protocolVersionMismatch
    case replayRejected

    public var errorDescription: String? {
        switch self {
        case .invalidKeyID:
            "The Loom session key identifier does not match the presented public key."
        case .invalidSignature:
            "The Loom session signature is invalid."
        case .protocolVersionMismatch:
            "The Loom session protocol version is incompatible."
        case .replayRejected:
            "The Loom session hello was rejected as a replay."
        }
    }
}

private struct LoomCanonicalHelloPayload: Codable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: DeviceType
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

package struct LoomPreparedSessionHello {
    package let hello: LoomSessionHello
    package let ephemeralPrivateKey: P256.KeyAgreement.PrivateKey
}

package struct LoomValidatedSessionHello {
    package let peerIdentity: LoomPeerIdentity
    package let hello: LoomSessionHello
}

/// Builds and validates signed Loom session hellos.
public actor LoomSessionHelloValidator {
    private let replayProtector: LoomReplayProtector

    public init(replayProtector: LoomReplayProtector = LoomReplayProtector()) {
        self.replayProtector = replayProtector
    }

    @MainActor
    public static func makeSignedHello(
        from request: LoomSessionHelloRequest,
        identityManager: LoomIdentityManager = .shared
    ) throws -> LoomSessionHello {
        try makePreparedSignedHello(
            from: request,
            identityManager: identityManager
        )
        .hello
    }

    @MainActor
    package static func makePreparedSignedHello(
        from request: LoomSessionHelloRequest,
        identityManager: LoomIdentityManager = .shared
    ) throws -> LoomPreparedSessionHello {
        let identity = try identityManager.currentIdentity()
        let ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralPrivateKey.publicKey.x963Representation
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString.lowercased()
        let canonical = LoomCanonicalHelloPayload(
            deviceID: request.deviceID,
            deviceName: request.deviceName,
            deviceType: request.deviceType,
            protocolVersion: Int(Loom.protocolVersion),
            advertisement: request.advertisement,
            supportedFeatures: request.supportedFeatures.sorted(),
            iCloudUserID: request.iCloudUserID,
            keyID: identity.keyID,
            publicKey: identity.publicKey,
            ephemeralPublicKey: ephemeralPublicKey,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let payload = try canonicalPayload(from: canonical)
        let signature = try identityManager.sign(payload)
        let hello = LoomSessionHello(
            deviceID: request.deviceID,
            deviceName: request.deviceName,
            deviceType: request.deviceType,
            protocolVersion: Int(Loom.protocolVersion),
            advertisement: request.advertisement,
            supportedFeatures: request.supportedFeatures.sorted(),
            iCloudUserID: request.iCloudUserID,
            identity: .init(
                keyID: identity.keyID,
                publicKey: identity.publicKey,
                ephemeralPublicKey: ephemeralPublicKey,
                timestampMs: timestampMs,
                nonce: nonce,
                signature: signature
            )
        )
        return LoomPreparedSessionHello(
            hello: hello,
            ephemeralPrivateKey: ephemeralPrivateKey
        )
    }

    public func validate(
        _ hello: LoomSessionHello,
        endpointDescription: String
    ) async throws -> LoomPeerIdentity {
        try await validateDetailed(
            hello,
            endpointDescription: endpointDescription
        )
        .peerIdentity
    }

    package func validateDetailed(
        _ hello: LoomSessionHello,
        endpointDescription: String
    ) async throws -> LoomValidatedSessionHello {
        guard hello.protocolVersion == Int(Loom.protocolVersion) else {
            throw LoomSessionHelloError.protocolVersionMismatch
        }

        let derivedKeyID = LoomIdentityManager.keyID(for: hello.identity.publicKey)
        guard derivedKeyID == hello.identity.keyID else {
            throw LoomSessionHelloError.invalidKeyID
        }

        let payload = try Self.canonicalPayload(
            from: LoomCanonicalHelloPayload(
                deviceID: hello.deviceID,
                deviceName: hello.deviceName,
                deviceType: hello.deviceType,
                protocolVersion: hello.protocolVersion,
                advertisement: hello.advertisement,
                supportedFeatures: hello.supportedFeatures.sorted(),
                iCloudUserID: hello.iCloudUserID,
                keyID: hello.identity.keyID,
                publicKey: hello.identity.publicKey,
                ephemeralPublicKey: hello.identity.ephemeralPublicKey,
                timestampMs: hello.identity.timestampMs,
                nonce: hello.identity.nonce
            )
        )

        guard LoomIdentityManager.verify(
            signature: hello.identity.signature,
            payload: payload,
            publicKey: hello.identity.publicKey
        ) else {
            throw LoomSessionHelloError.invalidSignature
        }

        guard await replayProtector.validate(
            timestampMs: hello.identity.timestampMs,
            nonce: hello.identity.nonce
        ) else {
            throw LoomSessionHelloError.replayRejected
        }

        return LoomValidatedSessionHello(
            peerIdentity: LoomPeerIdentity(
                deviceID: hello.deviceID,
                name: hello.deviceName,
                deviceType: hello.deviceType,
                iCloudUserID: hello.iCloudUserID,
                identityKeyID: hello.identity.keyID,
                identityPublicKey: hello.identity.publicKey,
                isIdentityAuthenticated: true,
                endpoint: endpointDescription
            ),
            hello: hello
        )
    }

    private static func canonicalPayload(from hello: LoomCanonicalHelloPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(hello)
    }
}
