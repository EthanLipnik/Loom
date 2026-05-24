//
//  LoomConnectionFactory.swift
//  Loom
//
//  Created by Ethan Lipnik on 5/24/26.
//

import Foundation
import Network

package enum LoomConnectionFactory {
    package static func makeConnection(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        configuration: LoomNetworkConfiguration,
        enablePeerToPeer: Bool?,
        requiredInterface: NWInterface?,
        requiredInterfaceType: NWInterface.InterfaceType?,
        requiredLocalPort: UInt16?
    ) throws -> LoomConnection {
        switch transportKind {
        case .tcp, .udp:
            return try makeNWConnection(
                to: endpoint,
                using: transportKind,
                configuration: configuration,
                enablePeerToPeer: enablePeerToPeer,
                requiredInterface: requiredInterface,
                requiredInterfaceType: requiredInterfaceType,
                requiredLocalPort: requiredLocalPort
            )
        case .quic:
            return .quic(
                try LoomQUICTransportFactory.makeConnection(
                    to: endpoint,
                    enablePeerToPeer: enablePeerToPeer ?? configuration.enablePeerToPeer,
                    requiredInterface: requiredInterface,
                    requiredInterfaceType: requiredInterfaceType,
                    requiredLocalPort: requiredLocalPort,
                    quicALPN: configuration.quicALPN,
                    serviceClass: configuration.directDatagramServiceClass
                )
            )
        }
    }

    private static func makeNWConnection(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        configuration: LoomNetworkConfiguration,
        enablePeerToPeer: Bool?,
        requiredInterface: NWInterface?,
        requiredInterfaceType: NWInterface.InterfaceType?,
        requiredLocalPort: UInt16?
    ) throws -> LoomConnection {
        guard let nwTransportKind = LoomNWConnectionTransportKind(transportKind) else {
            throw LoomError.protocolError("Transport \(transportKind.rawValue) is not backed by NWConnection.")
        }
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: nwTransportKind,
            enablePeerToPeer: enablePeerToPeer ?? configuration.enablePeerToPeer,
            requiredInterface: requiredInterface,
            requiredInterfaceType: requiredInterfaceType,
            udpServiceClass: configuration.directDatagramServiceClass
        )
        if let requiredLocalPort, let port = NWEndpoint.Port(rawValue: requiredLocalPort) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: port)
            parameters.allowLocalEndpointReuse = true
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        return LoomConnection(connection: connection, transportKind: nwTransportKind)
    }
}
