//
//  LoomQUICTransportFactory.swift
//  Loom
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Dispatch
import Foundation
import Network
import Security

package enum LoomQUICTransportFactory {
    package static let defaultMaxDatagramFrameSize = 1200

    package static func makeConnection(
        to endpoint: NWEndpoint,
        enablePeerToPeer: Bool,
        requiredInterface: NWInterface?,
        requiredInterfaceType: NWInterface.InterfaceType?,
        requiredLocalPort: UInt16?,
        quicALPN: [String],
        serviceClass: NWParameters.ServiceClass
    ) throws -> NetworkConnection<QUIC> {
        var builder = try makeParameters(
            enablePeerToPeer: enablePeerToPeer,
            requiredInterface: requiredInterface,
            requiredInterfaceType: requiredInterfaceType,
            localPort: requiredLocalPort,
            quicALPN: quicALPN,
            serviceClass: serviceClass,
            requiresLocalIdentity: false
        )
        builder = builder.localEndpointReuseAllowed(requiredLocalPort != nil)
        return NetworkConnection(to: endpoint, using: builder)
    }

    package static func makeListener(
        port requestedPort: UInt16,
        enablePeerToPeer: Bool,
        quicALPN: [String],
        serviceClass: NWParameters.ServiceClass
    ) throws -> NetworkListener<QUIC> {
        let builder = try makeParameters(
            enablePeerToPeer: enablePeerToPeer,
            requiredInterface: nil,
            requiredInterfaceType: nil,
            localPort: requestedPort == 0 ? nil : requestedPort,
            quicALPN: quicALPN,
            serviceClass: serviceClass,
            requiresLocalIdentity: true
        )
        return try NetworkListener(using: builder)
    }

    private static func makeParameters(
        enablePeerToPeer: Bool,
        requiredInterface: NWInterface?,
        requiredInterfaceType: NWInterface.InterfaceType?,
        localPort: UInt16?,
        quicALPN: [String],
        serviceClass: NWParameters.ServiceClass,
        requiresLocalIdentity: Bool
    ) throws -> NWParametersBuilder<QUIC> {
        let tlsIdentity = LoomQUICTLSConfiguration.makeIdentity(commonName: "Loom QUIC")
        if requiresLocalIdentity, tlsIdentity == nil {
            throw LoomQUICTransportFactoryError.tlsIdentityUnavailable
        }
        var builder = NWParametersBuilder.parameters {
            Self.configureTLS(
                QUIC(alpn: quicALPN.isEmpty ? ["loom"] : quicALPN),
                identity: tlsIdentity
            )
                .maxDatagramFrameSize(defaultMaxDatagramFrameSize)
                .initialMaxData(8 * 1024 * 1024)
                .initialMaxStreamDataBidirectionalLocal(2 * 1024 * 1024)
                .initialMaxStreamDataBidirectionalRemote(2 * 1024 * 1024)
                .initialMaxBidirectionalStreams(4)
                .idleTimeout(30)
        }
        builder = builder
            .peerToPeerIncluded(enablePeerToPeer)
            .serviceClass(serviceClass)
            .localEndpointReuseAllowed(true)
        if let requiredInterface {
            builder = builder.requiredInterface(requiredInterface)
        }
        if let requiredInterfaceType {
            builder = builder.requiredInterfaceType(requiredInterfaceType)
        }
        if let localPort, let port = NWEndpoint.Port(rawValue: localPort) {
            builder = builder.localPort(port)
        }
        return builder
    }

    private static func configureTLS(_ quic: QUIC, identity: sec_identity_t?) -> QUIC {
        var configured = quic
            .tls
            .peerAuthentication(.none)
            .tls
            .certificateValidator { _, _ in true }
        if let identity {
            configured = configured.tls.localIdentity(identity)
        } else {
            LoomLogger.transport("QUIC TLS identity unavailable; handshake may fail before Loom authentication")
        }
        return configured
    }
}

private enum LoomQUICTransportFactoryError: Error, LocalizedError {
    case tlsIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .tlsIdentityUnavailable:
            "QUIC listener could not create a local TLS identity"
        }
    }
}

package enum LoomQUICTLSConfiguration {
    package static func configure(
        _ options: sec_protocol_options_t,
        identity: sec_identity_t?,
        logPrefix: String
    ) {
        sec_protocol_options_set_peer_authentication_required(options, false)
        sec_protocol_options_set_verify_block(
            options,
            { _, _, complete in
                complete(true)
            },
            DispatchQueue.global(qos: .userInitiated)
        )

        if let identity {
            sec_protocol_options_set_local_identity(options, identity)
        } else {
            LoomLogger.transport("\(logPrefix) TLS identity unavailable; handshake may fail before Loom authentication")
        }
    }

    package static func makeIdentity(commonName: String) -> sec_identity_t? {
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
        ]
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyError),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            LoomLogger.transport("Failed to create QUIC TLS key: \(String(describing: keyError?.takeRetainedValue()))")
            return nil
        }

        guard let certificateData = makeSelfSignedCertificateData(
            commonName: commonName,
            publicKeyData: publicKeyData,
            privateKey: privateKey
        ), let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let identity = SecIdentityCreate(nil, certificate, privateKey),
              let protocolIdentity = sec_identity_create(identity) else {
            LoomLogger.transport("Failed to create QUIC TLS identity")
            return nil
        }
        return protocolIdentity
    }

    private static func makeSelfSignedCertificateData(
        commonName: String,
        publicKeyData: Data,
        privateKey: SecKey
    ) -> Data? {
        let algorithm = algorithmIdentifier(
            oid: [1, 2, 840, 10045, 4, 3, 2],
            parameters: nil
        )
        let tbsCertificate = sequence([
            integer(randomSerialBytes()),
            algorithm,
            name(commonName: commonName),
            sequence([
                generalizedTime("20200101000000Z"),
                generalizedTime("20491231235959Z"),
            ]),
            name(commonName: commonName),
            subjectPublicKeyInfo(publicKeyData: publicKeyData),
        ])

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signError
        ) as Data? else {
            LoomLogger.transport("Failed to sign QUIC TLS certificate: \(String(describing: signError?.takeRetainedValue()))")
            return nil
        }

        return sequence([
            tbsCertificate,
            algorithm,
            bitString(signature),
        ])
    }

    private static func subjectPublicKeyInfo(publicKeyData: Data) -> Data {
        sequence([
            algorithmIdentifier(
                oid: [1, 2, 840, 10045, 2, 1],
                parameters: objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
            ),
            bitString(publicKeyData),
        ])
    }

    private static func algorithmIdentifier(oid: [Int], parameters: Data?) -> Data {
        var values = [objectIdentifier(oid)]
        if let parameters {
            values.append(parameters)
        }
        return sequence(values)
    }

    private static func name(commonName: String) -> Data {
        sequence([
            set([
                sequence([
                    objectIdentifier([2, 5, 4, 3]),
                    utf8String(commonName),
                ]),
            ]),
        ])
    }

    private static func randomSerialBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = Array(UUID().uuidString.utf8.prefix(16))
        }
        bytes[0] &= 0x7F
        if bytes.allSatisfy({ $0 == 0 }) {
            bytes[bytes.count - 1] = 1
        }
        return Data(bytes)
    }

    private static func sequence(_ values: [Data]) -> Data {
        der(tag: 0x30, content: values.reduce(into: Data()) { $0.append($1) })
    }

    private static func set(_ values: [Data]) -> Data {
        der(tag: 0x31, content: values.reduce(into: Data()) { $0.append($1) })
    }

    private static func integer(_ bytes: Data) -> Data {
        var content = bytes
        while content.count > 1, content.first == 0, (content.dropFirst().first ?? 0) < 0x80 {
            content.removeFirst()
        }
        if (content.first ?? 0) >= 0x80 {
            content.insert(0, at: 0)
        }
        return der(tag: 0x02, content: content)
    }

    private static func objectIdentifier(_ components: [Int]) -> Data {
        guard components.count >= 2 else { return der(tag: 0x06, content: Data()) }
        var encoded = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            encoded.append(contentsOf: base128(component))
        }
        return der(tag: 0x06, content: encoded)
    }

    private static func bitString(_ data: Data) -> Data {
        var content = Data([0])
        content.append(data)
        return der(tag: 0x03, content: content)
    }

    private static func utf8String(_ value: String) -> Data {
        der(tag: 0x0C, content: Data(value.utf8))
    }

    private static func generalizedTime(_ value: String) -> Data {
        der(tag: 0x18, content: Data(value.utf8))
    }

    private static func der(tag: UInt8, content: Data) -> Data {
        var data = Data([tag])
        data.append(contentsOf: length(content.count))
        data.append(content)
        return data
    }

    private static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 {
            return [UInt8(count)]
        }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func base128(_ value: Int) -> [UInt8] {
        var remaining = value
        var bytes = [UInt8(remaining & 0x7F)]
        remaining >>= 7
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return bytes
    }
}
