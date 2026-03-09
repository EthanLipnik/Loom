//
//  LoomRemoteSignalingSecurityTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Security validation coverage for remote signaling configuration.
//

@testable import Loom
import Foundation
import Testing

@Suite("Remote Signaling Security")
struct LoomRemoteSignalingSecurityTests {
    @Test("Remote signaling auth HTTP failures are marked permanent")
    func remoteSignalingAuthHTTPFailuresArePermanent() {
        let unauthorized = LoomRelayError.http(
            statusCode: 401,
            errorCode: "auth_failed",
            detail: "signature_verification_failed"
        )
        let forbidden = LoomRelayError.http(
            statusCode: 403,
            errorCode: "auth_failed",
            detail: nil
        )

        #expect(unauthorized.isAuthenticationFailure)
        #expect(forbidden.isAuthenticationFailure)
        #expect(unauthorized.isPermanentConfigurationFailure)
        #expect(forbidden.isPermanentConfigurationFailure)
    }

    @Test("Remote signaling non-auth HTTP failures are not marked permanent")
    func remoteSignalingNonAuthHTTPFailuresAreNotPermanent() {
        let rateLimited = LoomRelayError.http(
            statusCode: 429,
            errorCode: "rate_limited",
            detail: nil
        )

        #expect(rateLimited.isAuthenticationFailure == false)
        #expect(rateLimited.isPermanentConfigurationFailure == false)
    }

    @Test("Invalid signaling configuration is permanent")
    func invalidSignalingConfigurationIsPermanent() {
        let error = LoomRelayError.invalidConfiguration
        #expect(error.isAuthenticationFailure == false)
        #expect(error.isPermanentConfigurationFailure)
    }

    @MainActor
    @Test("Remote signaling rejects non-HTTPS base URL")
    func remoteSignalingRejectsNonHTTPSBaseURL() async {
        let configuration = LoomRelayConfiguration(
            baseURL: URL(string: "http://example.com")!,
            appAuthentication: LoomRelayAppAuthentication(
                appID: "test-app",
                sharedSecret: "test-secret"
            )
        )
        let client = LoomRelayClient(configuration: configuration)

        do {
            try await client.joinSession(sessionID: "session-1")
            Issue.record("Expected invalidConfiguration for non-HTTPS signaling URL.")
        } catch let error as LoomRelayError {
            switch error {
            case .invalidConfiguration:
                break
            default:
                Issue.record("Expected invalidConfiguration, got \(error.localizedDescription).")
            }
        } catch {
            Issue.record("Expected LoomRelayError, got \(error.localizedDescription).")
        }
    }
}
