//
//  BonjourAdvertiser.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network

/// Advertises a Loom peer service via Bonjour.
actor BonjourAdvertiser {
    private var listener: NWListener?
    private let serviceType: String
    private let serviceName: String
    private var advertisement: LoomPeerAdvertisement
    private let enablePeerToPeer: Bool

    private var isAdvertising = false

    init(
        serviceName: String,
        advertisement: LoomPeerAdvertisement = LoomPeerAdvertisement(),
        serviceType: String = Loom.serviceType,
        enablePeerToPeer: Bool = true
    ) {
        self.serviceName = serviceName
        self.advertisement = advertisement
        self.serviceType = serviceType
        self.enablePeerToPeer = enablePeerToPeer
    }

    /// Start advertising the service
    func start(port: UInt16 = 0, onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        guard !isAdvertising else { throw LoomError.alreadyAdvertising }

        let parameters = NWParameters.tcp
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = enablePeerToPeer

        // Favor low-latency control delivery and quicker dead-peer detection.
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveInterval = 5
        }

        let actualPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!

        listener = try NWListener(using: parameters, on: actualPort)

        // Configure Bonjour advertisement with TXT record
        let txtRecord = NWTXTRecord(advertisement.toTXTRecord())
        listener?.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            txtRecord: txtRecord
        )

        // Set connection handler BEFORE starting the listener
        listener?.newConnectionHandler = onConnection

        // Capture listener reference for the closure
        guard let listener else { throw LoomError.protocolError("Failed to create listener") }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)

            listener.stateUpdateHandler = { [weak self, continuationBox] state in
                LoomLogger.discovery("Advertiser state: \(state)")
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        Task { await self?.setAdvertising(true) }
                        continuationBox.resume(returning: port)
                    }
                case let .failed(error):
                    Task { await self?.setAdvertising(false) }
                    continuationBox.resume(throwing: error)
                case let .waiting(error):
                    LoomLogger.discovery("Advertiser waiting: \(error)")
                case .cancelled:
                    Task { await self?.setAdvertising(false) }
                    continuationBox.resume(throwing: LoomError.protocolError("Listener cancelled"))
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInteractive))
        }
    }

    private func setAdvertising(_ value: Bool) {
        isAdvertising = value
    }

    /// Stop advertising
    func stop() {
        listener?.cancel()
        listener = nil
        isAdvertising = false
    }

    /// Update TXT record with a new advertisement payload.
    func updateAdvertisement(_ advertisement: LoomPeerAdvertisement) {
        self.advertisement = advertisement
        let txtRecord = NWTXTRecord(advertisement.toTXTRecord())
        listener?.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            txtRecord: txtRecord
        )
    }

    var port: UInt16? { listener?.port?.rawValue }
}
