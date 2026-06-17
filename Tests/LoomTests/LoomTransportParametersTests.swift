//
//  LoomTransportParametersTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 6/17/26.
//

@testable import Loom
import Testing

@Suite("Transport Parameters")
struct LoomTransportParametersTests {
    @Test("Peer-to-peer direct parameters allow ultra-constrained paths")
    func peerToPeerDirectParametersAllowUltraConstrainedPaths() throws {
        let tcpParameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: true
        )
        let udpParameters = try LoomTransportParametersFactory.makeParameters(
            for: .udp,
            enablePeerToPeer: true
        )

        #expect(tcpParameters.includePeerToPeer)
        #expect(tcpParameters.allowUltraConstrainedPaths)
        #expect(udpParameters.includePeerToPeer)
        #expect(udpParameters.allowUltraConstrainedPaths)
    }

    @Test("Non-peer-to-peer direct parameters keep ultra-constrained paths disabled")
    func nonPeerToPeerDirectParametersKeepUltraConstrainedPathsDisabled() throws {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: false
        )

        #expect(!parameters.includePeerToPeer)
        #expect(!parameters.allowUltraConstrainedPaths)
    }

    @Test("Bonjour peer-to-peer parameters allow ultra-constrained paths")
    func bonjourPeerToPeerParametersAllowUltraConstrainedPaths() {
        #expect(BonjourAdvertiser.makeAdvertiserParameters(enablePeerToPeer: true).allowUltraConstrainedPaths)
        #expect(LoomDiscovery.makeBrowserParameters(enablePeerToPeer: true).allowUltraConstrainedPaths)
    }
}
