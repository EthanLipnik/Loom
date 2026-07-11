//
//  LoomConnectionFactory.swift
//  Loom
//
//  Created by Ethan Lipnik on 5/24/26.
//

#if canImport(Network)
import Foundation
import LoomNetworking
import Network

package enum LoomConnectionFactory {
    package static func makeBackendConnection(
        to endpoint: NWEndpoint,
        using transportKind: LoomTransportKind,
        configuration: LoomNetworkConfiguration,
        backend: any LoomNetworkBackend,
        enablePeerToPeer: Bool?,
        requiredInterface: NWInterface?,
        requiredInterfaceType: NWInterface.InterfaceType?,
        requiredLocalPort: UInt16?
    ) throws -> any LoomNetworkConnection {
        if let nativeBackend = backend as? LoomNetworkFrameworkBackend {
            return try nativeBackend.makeNativeConnection(
                to: endpoint,
                using: transportKind,
                enablePeerToPeer: enablePeerToPeer ?? configuration.enablePeerToPeer,
                requiredInterface: requiredInterface,
                requiredInterfaceType: requiredInterfaceType,
                requiredLocalPort: requiredLocalPort,
                datagramServiceClass: configuration.directDatagramServiceClass
            )
        }

        guard let backendEndpoint = LoomNetworkEndpoint(endpoint) else {
            throw LoomNetworkError(
                code: .unsupported,
                detail: "The selected network backend cannot represent endpoint \(endpoint)."
            )
        }
        return try backend.makeConnection(
            to: backendEndpoint,
            using: transportKind.networkTransportKind,
            configuration: LoomNetworkConnectionConfiguration(
                enablePeerToPeer: enablePeerToPeer ?? configuration.enablePeerToPeer,
                requiredInterface: requiredInterface.map(LoomNetworkInterface.init),
                requiredInterfaceType: requiredInterfaceType.map(LoomNetworkInterfaceType.init),
                requiredLocalPort: requiredLocalPort,
                datagramServiceClass: LoomNetworkServiceClass(
                    configuration.directDatagramServiceClass
                )
            )
        )
    }
}

#endif
