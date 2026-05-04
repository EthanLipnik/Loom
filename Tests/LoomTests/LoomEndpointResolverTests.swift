//
//  LoomEndpointResolverTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/5/26.
//

@testable import Loom
import Network
import Testing

@Suite("Loom Endpoint Resolver")
struct LoomEndpointResolverTests {
    @Test("Local host resolution falls back to the original hostname when pre-resolution fails")
    func localHostResolutionFallsBackToOriginalHostname() async throws {
        let port: UInt16 = 61_714

        let endpoint = try await LoomEndpointResolver.resolveHostPort(
            host: "ethansmacstudio.local",
            port: port,
            resolver: { _, _ in
                throw LoomError.protocolError(
                    "Failed to resolve ethansmacstudio.local: nodename nor servname provided, or not known"
                )
            }
        )

        let expectedEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("ethansmacstudio.local"),
            port: try #require(NWEndpoint.Port(rawValue: port))
        )
        #expect(endpoint.debugDescription == expectedEndpoint.debugDescription)
    }

    @Test("Non-local hosts bypass the pre-resolver")
    func nonLocalHostsBypassPreResolver() async throws {
        let port: UInt16 = 61_714
        let endpoint = try await LoomEndpointResolver.resolveHostPort(
            host: "100.64.10.2",
            port: port,
            resolver: { _, _ in
                Issue.record("Non-local hosts should not invoke the Bonjour pre-resolver.")
                return NWEndpoint.Host("203.0.113.44")
            }
        )

        let expectedEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.64.10.2"),
            port: try #require(NWEndpoint.Port(rawValue: port))
        )
        #expect(endpoint.debugDescription == expectedEndpoint.debugDescription)
    }

    @Test("Peer-to-peer local hosts bypass pre-resolution")
    func peerToPeerLocalHostsBypassPreResolution() {
        #expect(
            !LoomEndpointResolver.shouldPreResolveLocalHost(
                "ethansmacstudio.local",
                enablePeerToPeer: true
            )
        )
        #expect(
            LoomEndpointResolver.shouldPreResolveLocalHost(
                "ethansmacstudio.local",
                enablePeerToPeer: false
            )
        )
    }
}
