//
//  LoomDirectListener.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Network

package actor LoomDirectListener {
    private var listener: NWListener?
    private let transportKind: LoomTransportKind
    private let enablePeerToPeer: Bool

    package init(
        transportKind: LoomTransportKind,
        enablePeerToPeer: Bool
    ) {
        self.transportKind = transportKind
        self.enablePeerToPeer = enablePeerToPeer
    }

    package func start(
        port: UInt16 = 0,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> UInt16 {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: transportKind,
            enablePeerToPeer: enablePeerToPeer
        )
        let actualPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any
        listener = try NWListener(using: parameters, on: actualPort)
        listener?.newConnectionHandler = onConnection
        guard let listener else {
            throw LoomError.protocolError("Failed to create Loom direct listener.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuationBox.resume(returning: port)
                    }
                case let .failed(error):
                    continuationBox.resume(throwing: error)
                case .cancelled:
                    continuationBox.resume(throwing: LoomError.protocolError("Direct listener cancelled."))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    package func stop() {
        listener?.cancel()
        listener = nil
    }
}

package enum LoomTransportParametersFactory {
    package static func makeParameters(
        for transportKind: LoomTransportKind,
        enablePeerToPeer: Bool,
        requiredInterfaceType: NWInterface.InterfaceType? = nil
    ) throws -> NWParameters {
        let parameters: NWParameters
        switch transportKind {
        case .tcp:
            parameters = NWParameters.tcp
            parameters.includePeerToPeer = enablePeerToPeer
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveInterval = 5
            }
        case .quic:
            let options = NWProtocolQUIC.Options()
            parameters = NWParameters(quic: options)
            parameters.includePeerToPeer = enablePeerToPeer
        }
        if let requiredInterfaceType {
            parameters.requiredInterfaceType = requiredInterfaceType
        }
        return parameters
    }
}

