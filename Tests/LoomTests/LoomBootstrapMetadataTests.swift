//
//  LoomBootstrapMetadataTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Bootstrap metadata serialization and Wake-on-LAN packet coverage.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Bootstrap Metadata")
struct LoomBootstrapMetadataTests {
    @Test("Bootstrap metadata codable roundtrip")
    func bootstrapMetadataCodableRoundtrip() throws {
        let metadata = LoomBootstrapMetadata(
            enabled: true,
            supportsControlChannel: true,
            supportsCredentialSubmission: true,
            endpoints: [
                LoomBootstrapEndpoint(host: "host-a.local", port: 22, source: .user),
                LoomBootstrapEndpoint(host: "10.0.0.21", port: 22, source: .auto),
            ],
            sshPort: 22,
            controlPort: 9851,
            wakeOnLAN: LoomWakeOnLANInfo(
                macAddress: "AA:BB:CC:DD:EE:FF",
                broadcastAddresses: ["10.0.0.255", "192.168.1.255"]
            )
        )

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(LoomBootstrapMetadata.self, from: encoded)

        #expect(decoded == metadata)
        #expect(decoded.version == LoomBootstrapMetadata.currentVersion)
        #expect(decoded.endpoints.count == 2)
        #expect(decoded.wakeOnLAN?.broadcastAddresses.count == 2)
    }

    @Test("Wake-on-LAN magic packet format")
    func wakeOnLANMagicPacketFormat() throws {
        let packet = try LoomDefaultWakeOnLANClient.magicPacketData(for: "AA-BB-CC-DD-EE-FF")
        #expect(packet.count == 102)

        let bytes = [UInt8](packet)
        #expect(bytes.prefix(6).allSatisfy { $0 == 0xFF })

        let expectedMAC: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        #expect(Array(bytes[6 ..< 12]) == expectedMAC)
        #expect(Array(bytes[96 ..< 102]) == expectedMAC)
    }

    @Test("Wake-on-LAN invalid MAC rejection")
    func wakeOnLANInvalidMACRejection() {
        do {
            _ = try LoomDefaultWakeOnLANClient.magicPacketData(for: "invalid")
            Issue.record("Expected invalid MAC address rejection.")
        } catch let error as LoomWakeOnLANError {
            switch error {
            case .invalidMACAddress:
                break
            default:
                Issue.record("Expected invalidMACAddress, got \(error.localizedDescription).")
            }
        } catch {
            Issue.record("Expected LoomWakeOnLANError, got \(error.localizedDescription).")
        }
    }

    @Test("Bootstrap endpoint resolution order and dedupe")
    func bootstrapEndpointResolutionOrderAndDedupe() {
        let resolved = LoomBootstrapEndpointResolver.resolve([
            LoomBootstrapEndpoint(host: "10.0.0.5", port: 22, source: .auto),
            LoomBootstrapEndpoint(host: "bootstrap.example.com", port: 2222, source: .user),
            LoomBootstrapEndpoint(host: "10.0.0.5", port: 22, source: .lastSeen),
            LoomBootstrapEndpoint(host: "10.0.0.9", port: 22, source: .auto),
            LoomBootstrapEndpoint(host: "Bootstrap.Example.Com", port: 2222, source: .lastSeen),
            LoomBootstrapEndpoint(host: "198.51.100.22", port: 22, source: .lastSeen),
        ])

        #expect(resolved == [
            LoomBootstrapEndpoint(host: "bootstrap.example.com", port: 2222, source: .user),
            LoomBootstrapEndpoint(host: "10.0.0.5", port: 22, source: .auto),
            LoomBootstrapEndpoint(host: "10.0.0.9", port: 22, source: .auto),
            LoomBootstrapEndpoint(host: "198.51.100.22", port: 22, source: .lastSeen),
        ])
    }

    @Test("SSH bootstrap rejects invalid endpoint")
    func sshBootstrapRejectsInvalidEndpoint() async {
        let client = LoomDefaultSSHBootstrapClient()
        do {
            _ = try await client.submitCredentialsOverSSH(
                endpoint: LoomBootstrapEndpoint(host: "   ", port: 22, source: .auto),
                username: "user",
                password: "password",
                expectedHostKeyFingerprint: "SHA256:test-fingerprint",
                timeout: .seconds(1)
            )
            Issue.record("Expected invalid endpoint rejection.")
        } catch let error as LoomSSHBootstrapError {
            switch error {
            case .invalidEndpoint:
                break
            default:
                Issue.record("Expected invalidEndpoint, got \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Expected LoomSSHBootstrapError, got \(error.localizedDescription)")
        }
    }

    @Test("SSH bootstrap rejects missing host fingerprint")
    func sshBootstrapRejectsMissingHostFingerprint() async {
        let client = LoomDefaultSSHBootstrapClient()
        do {
            _ = try await client.submitCredentialsOverSSH(
                endpoint: LoomBootstrapEndpoint(host: "127.0.0.1", port: 22, source: .auto),
                username: "user",
                password: "password",
                expectedHostKeyFingerprint: "   ",
                timeout: .seconds(1)
            )
            Issue.record("Expected missing host-key fingerprint rejection.")
        } catch let error as LoomSSHBootstrapError {
            switch error {
            case .missingHostKeyFingerprint:
                break
            default:
                Issue.record("Expected missingHostKeyFingerprint, got \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Expected LoomSSHBootstrapError, got \(error.localizedDescription)")
        }
    }

    @Test("Bootstrap control protocol codable roundtrip")
    func bootstrapControlProtocolCodableRoundtrip() throws {
        let auth = LoomBootstrapControlAuthEnvelope(
            keyID: "test-key-id",
            publicKey: Data([0x01, 0x02, 0x03]),
            timestampMs: 1_700_000_000_000,
            nonce: "test-nonce",
            signature: Data([0xAA, 0xBB, 0xCC])
        )
        let encrypted = LoomBootstrapEncryptedCredentialsPayload(combined: Data([0x10, 0x20, 0x30]))
        let request = LoomBootstrapControlRequest(
            operation: .submitCredentials,
            auth: auth,
            credentialsPayload: encrypted
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(LoomBootstrapControlRequest.self, from: requestData)
        #expect(decodedRequest.operation == .submitCredentials)
        #expect(decodedRequest.auth == auth)
        #expect(decodedRequest.credentialsPayload == encrypted)
        #expect(decodedRequest.requestID == request.requestID)

        let response = LoomBootstrapControlResponse(
            requestID: request.requestID,
            success: true,
            availability: .ready,
            message: "Peer session is ready.",
            canRetry: false,
            retriesRemaining: nil,
            retryAfterSeconds: nil
        )
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(LoomBootstrapControlResponse.self, from: responseData)
        #expect(decodedResponse.requestID == request.requestID)
        #expect(decodedResponse.success)
        #expect(decodedResponse.availability == .ready)
    }
}
