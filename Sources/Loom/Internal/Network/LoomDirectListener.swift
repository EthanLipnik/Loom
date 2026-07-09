//
//  LoomDirectListener.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Network

package typealias LoomDirectConnectionHandler = @Sendable (LoomConnection) async -> Void

package protocol LoomDirectTransportListener: Sendable {
    func start(
        port: UInt16,
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16

    func stop() async
}

package actor LoomDirectListener: LoomDirectTransportListener {
    private var listener: NWListener?
    private let transportKind: LoomNWConnectionTransportKind
    private let enablePeerToPeer: Bool
    private let udpServiceClass: NWParameters.ServiceClass

    package init(
        transportKind: LoomNWConnectionTransportKind,
        enablePeerToPeer: Bool,
        udpServiceClass: NWParameters.ServiceClass = .interactiveVideo
    ) {
        self.transportKind = transportKind
        self.enablePeerToPeer = enablePeerToPeer
        self.udpServiceClass = udpServiceClass
    }

    package func start(
        port: UInt16 = 0,
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16 {
        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: transportKind,
            enablePeerToPeer: enablePeerToPeer,
            udpServiceClass: udpServiceClass
        )
        let actualPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any
        parameters.allowLocalEndpointReuse = true
        let listenerTransportKind = transportKind
        let listenerPeerToPeerEnabled = enablePeerToPeer
        let listenerServiceClass = udpServiceClass
        let requestedPortDescription = port == 0 ? "any" : String(port)
        LoomLogger.transport(
            "Starting direct \(listenerTransportKind.rawValue) listener " +
                "requestedPort=\(requestedPortDescription) peerToPeer=\(listenerPeerToPeerEnabled) " +
                "serviceClass=\(listenerServiceClass)"
        )
        listener = try NWListener(using: parameters, on: actualPort)
        listener?.newConnectionHandler = { connection in
            LoomLogger.transport(
                "Direct \(listenerTransportKind.rawValue) listener accepted connection " +
                    "endpoint=\(connection.endpoint.debugDescription)"
            )
            Task {
                await onConnection(LoomConnection(connection: connection, transportKind: listenerTransportKind))
            }
        }
        guard let listener else {
            throw LoomError.protocolError("Failed to create Loom direct listener.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        LoomLogger.transport(
                            "Direct \(listenerTransportKind.rawValue) listener ready " +
                                "port=\(port) peerToPeer=\(listenerPeerToPeerEnabled)"
                        )
                        continuationBox.resume(returning: port)
                    }
                case let .waiting(error):
                    LoomLogger.transport(
                        "Direct \(listenerTransportKind.rawValue) listener waiting: \(error)"
                    )
                case let .failed(error):
                    LoomLogger.transport(
                        "Direct \(listenerTransportKind.rawValue) listener failed: \(error)"
                    )
                    continuationBox.resume(throwing: error)
                case .cancelled:
                    LoomLogger.transport(
                        "Direct \(listenerTransportKind.rawValue) listener cancelled"
                    )
                    continuationBox.resume(throwing: LoomError.protocolError("Direct listener cancelled."))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    package func stop() async {
        listener?.cancel()
        listener = nil
    }
}

package enum LoomTransportParametersFactory {
    package static func makeParameters(
        for transportKind: LoomNWConnectionTransportKind,
        enablePeerToPeer: Bool,
        requiredInterface: NWInterface? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        udpServiceClass: NWParameters.ServiceClass = .interactiveVideo
    ) throws -> NWParameters {
        let parameters: NWParameters
        switch transportKind {
        case .tcp:
            parameters = NWParameters.tcp
            parameters.includePeerToPeer = enablePeerToPeer
            if #available(iOS 26, macOS 26, visionOS 26, *) {
                parameters.allowUltraConstrainedPaths = enablePeerToPeer
            }
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveInterval = 5
            }
        case .udp:
            parameters = NWParameters.udp
            parameters.includePeerToPeer = enablePeerToPeer
            if #available(iOS 26, macOS 26, visionOS 26, *) {
                parameters.allowUltraConstrainedPaths = enablePeerToPeer
            }
            parameters.serviceClass = udpServiceClass
        }
        if let requiredInterface {
            parameters.requiredInterface = requiredInterface
        } else if let requiredInterfaceType {
            parameters.requiredInterfaceType = requiredInterfaceType
        }
        return parameters
    }
}
