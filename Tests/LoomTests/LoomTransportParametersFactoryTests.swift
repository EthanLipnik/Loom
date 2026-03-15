//
//  LoomTransportParametersFactoryTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/15/26.
//

@testable import Loom
import Network
import Testing

@Suite("LoomTransportParametersFactory")
struct LoomTransportParametersFactoryTests {
    @Test("makeParameters sets requiredInterfaceType when provided")
    func setsRequiredInterfaceType() throws {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: false,
            requiredInterfaceType: .wiredEthernet
        )
        #expect(parameters.requiredInterfaceType == .wiredEthernet)
    }

    @Test("makeParameters leaves requiredInterfaceType unset when nil")
    func leavesRequiredInterfaceTypeNil() throws {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: false
        )
        #expect(parameters.requiredInterfaceType == .other)
    }

    @Test("makeParameters sets requiredInterfaceType for wifi")
    func setsWifiInterfaceType() throws {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: false,
            requiredInterfaceType: .wifi
        )
        #expect(parameters.requiredInterfaceType == .wifi)
    }

    @Test("makeParameters preserves enablePeerToPeer with requiredInterfaceType")
    func preservesPeerToPeerWithInterfaceType() throws {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: true,
            requiredInterfaceType: .wiredEthernet
        )
        #expect(parameters.includePeerToPeer == true)
        #expect(parameters.requiredInterfaceType == .wiredEthernet)
    }
}
