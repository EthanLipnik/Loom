//
//  BonjourAdvertiser.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/2/26.
//

#if canImport(Network)
import Foundation
import Network

/// Advertises a Loom peer service via Bonjour.
///
/// The service type uses a `_tcp` suffix so Network.framework can resolve the
/// Bonjour endpoint reliably. Authenticated sessions publish their direct
/// TCP, UDP, and QUIC listener ports through TXT metadata so clients can
/// connect to the selected transport directly.
///
/// `NWConnection` cannot resolve Bonjour service endpoints whose type ends in
/// `_udp` because resolution times out before completing DNS-SD. The `_tcp`
/// service type keeps discovery reliable while TXT metadata carries the actual
/// direct transport ports.
actor BonjourAdvertiser {
    private var listener: NWListener?
    private let serviceType: String
    private let serviceName: String
    private var advertisement: LoomPeerAdvertisement
    private let enablePeerToPeer: Bool
    private let onFailureAfterReady: (@Sendable (String) -> Void)?

    private var isAdvertising = false

    init(
        serviceName: String,
        advertisement: LoomPeerAdvertisement = LoomPeerAdvertisement(),
        serviceType: String = Loom.serviceType,
        enablePeerToPeer: Bool = true,
        onFailureAfterReady: (@Sendable (String) -> Void)? = nil
    ) {
        self.serviceName = serviceName
        self.advertisement = advertisement
        self.serviceType = serviceType
        self.enablePeerToPeer = enablePeerToPeer
        self.onFailureAfterReady = onFailureAfterReady
    }

    /// Start advertising the service
    func start(port: UInt16 = 0, onConnection: @escaping LoomDirectConnectionHandler) async throws -> UInt16 {
        guard !isAdvertising else { throw LoomError.alreadyAdvertising }

        validateBonjourInfoPlistKeys(serviceType: serviceType)

        // TCP listener for Bonjour service registration, discovery, local
        // network permissions, and authenticated TCP fallback. Datagram-capable
        // sessions publish their direct listener ports through TXT metadata.
        // TODO: Investigate using a UDP Bonjour listener once NWConnection supports
        // resolving _udp service endpoints (rdar://FB...).
        let parameters = Self.makeAdvertiserParameters(enablePeerToPeer: enablePeerToPeer)

        let actualPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters, on: actualPort)

        // Configure Bonjour advertisement with TXT record
        let txtRecord = NWTXTRecord(advertisement.toTXTRecord())
        listener?.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            txtRecord: txtRecord
        )

        // Set connection handler BEFORE starting the listener
        listener?.newConnectionHandler = { connection in
            Task {
                await onConnection(
                    LoomNetworkFrameworkConnection(
                        connection: connection,
                        transportKind: .tcp
                    )
                )
            }
        }

        // Capture listener reference for the closure
        guard let listener else { throw LoomError.protocolError("Failed to create listener") }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)
            let startState = BonjourAdvertiserStartState()

            listener.stateUpdateHandler = { [weak self, continuationBox] state in
                LoomLogger.discovery("Advertiser state: \(state)")
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        startState.markReady()
                        Task { await self?.setAdvertising(true) }
                        continuationBox.resume(returning: port)
                    }
                case let .failed(error):
                    Task { await self?.setAdvertising(false) }
                    if startState.hasReportedReady {
                        self?.onFailureAfterReady?(String(describing: error))
                    } else {
                        continuationBox.resume(throwing: error)
                    }
                case let .waiting(error):
                    LoomLogger.discovery("Advertiser waiting: \(error)")
                case .cancelled:
                    Task { await self?.setAdvertising(false) }
                    if !startState.hasReportedReady {
                        continuationBox.resume(throwing: LoomError.protocolError("Listener cancelled"))
                    }
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInteractive))
        }
    }

    package static func makeAdvertiserParameters(enablePeerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = enablePeerToPeer
        if #available(iOS 26, macOS 26, visionOS 26, *) {
            parameters.allowUltraConstrainedPaths = enablePeerToPeer
        }

        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveInterval = 5
        }

        return parameters
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

    func currentAdvertisement() -> LoomPeerAdvertisement {
        advertisement
    }
}

private final class BonjourAdvertiserStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var reportedReady = false

    var hasReportedReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportedReady
    }

    func markReady() {
        lock.lock()
        reportedReady = true
        lock.unlock()
    }
}

#endif
