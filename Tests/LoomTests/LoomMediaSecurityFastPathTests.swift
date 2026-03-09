//
//  LoomMediaSecurityFastPathTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Fast-path encryption/decryption parity coverage.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Media Security Fast Path")
struct LoomMediaSecurityFastPathTests {
    @Test("Video raw-buffer encryption matches Data API output")
    func videoRawBufferEncryptionMatchesDataAPI() throws {
        let context = makeSecurityContext()
        let key = LoomMediaSecurity.makePacketKey(context: context)
        let payload = makePayload(byteCount: 1200)
        let header = FrameHeader(
            flags: [.keyframe, .encryptedPayload],
            streamID: 4,
            sequenceNumber: 77,
            timestamp: 123_456_789,
            frameNumber: 12,
            fragmentIndex: 1,
            fragmentCount: 3,
            payloadLength: UInt32(payload.count),
            frameByteCount: UInt32(payload.count * 3),
            checksum: 0,
            epoch: 9
        )

        let dataPath = try LoomMediaSecurity.encryptVideoPayload(
            payload,
            header: header,
            context: context,
            direction: .hostToClient
        )
        let rawPath = try payload.withUnsafeBytes { payloadBytes in
            try LoomMediaSecurity.encryptVideoPayload(
                payloadBytes,
                header: header,
                key: key,
                direction: .hostToClient
            )
        }

        #expect(rawPath == dataPath)
        #expect(rawPath.count == payload.count + LoomMediaSecurity.authTagLength)

        let decrypted = try LoomMediaSecurity.decryptVideoPayload(
            rawPath,
            header: header,
            key: key,
            direction: .hostToClient
        )
        #expect(decrypted == payload)
    }

    @Test("Audio raw-buffer encryption matches Data API output")
    func audioRawBufferEncryptionMatchesDataAPI() throws {
        let context = makeSecurityContext()
        let key = LoomMediaSecurity.makePacketKey(context: context)
        let payload = makePayload(byteCount: 900)
        let header = AudioPacketHeader(
            codec: .aacLC,
            flags: [.encryptedPayload],
            streamID: 2,
            sequenceNumber: 33,
            timestamp: 999_000,
            frameNumber: 8,
            fragmentIndex: 0,
            fragmentCount: 2,
            payloadLength: UInt16(payload.count),
            frameByteCount: UInt32(payload.count * 2),
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 1024,
            checksum: 0
        )

        let dataPath = try LoomMediaSecurity.encryptAudioPayload(
            payload,
            header: header,
            context: context,
            direction: .hostToClient
        )
        let rawPath = try payload.withUnsafeBytes { payloadBytes in
            try LoomMediaSecurity.encryptAudioPayload(
                payloadBytes,
                header: header,
                key: key,
                direction: .hostToClient
            )
        }

        #expect(rawPath == dataPath)
        #expect(rawPath.count == payload.count + LoomMediaSecurity.authTagLength)

        let decrypted = try LoomMediaSecurity.decryptAudioPayload(
            rawPath,
            header: header,
            key: key,
            direction: .hostToClient
        )
        #expect(decrypted == payload)
    }

    @Test("Checksum validation contract matches encrypted and unencrypted expectations")
    func checksumValidationContract() {
        #expect(!loomShouldValidatePayloadChecksum(isEncrypted: true, checksum: 0))
        #expect(loomShouldValidatePayloadChecksum(isEncrypted: true, checksum: 1))
        #expect(loomShouldValidatePayloadChecksum(isEncrypted: false, checksum: 0))
    }

    private func makePayload(byteCount: Int) -> Data {
        Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func makeSecurityContext() -> LoomMediaSecurityContext {
        LoomMediaSecurityContext(
            sessionKey: Data((0 ..< LoomMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) }),
            udpRegistrationToken: Data(repeating: 0x5C, count: LoomMediaSecurity.registrationTokenLength)
        )
    }
}
