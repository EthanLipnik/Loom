//
//  LoomOverlayProbe.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if canImport(Network)
import Foundation
import Network

package struct LoomOverlayProbeRequest: Codable, Sendable {
    package let protocolVersion: Int

    package init(protocolVersion: Int = Int(Loom.protocolVersion)) {
        self.protocolVersion = protocolVersion
    }
}

package struct LoomOverlayProbeResponse: Codable, Sendable, Equatable {
    package let name: String
    package let deviceType: DeviceType
    package let advertisement: LoomPeerAdvertisement
}

package actor LoomOverlayProbeServer {
    private let port: UInt16
    private let requestTimeout: Duration
    private let maxPendingConnections: Int
    private let outstandingOperationLimiter: LoomOutstandingOperationLimiter
    private let payloadProvider: @Sendable () async throws -> LoomOverlayProbeResponse
    private var listener: NWListener?
    private var pendingConnectionCount = 0

    package init(
        port: UInt16,
        requestTimeout: Duration = .seconds(10),
        maxPendingConnections: Int = 16,
        payloadProvider: @escaping @Sendable () async throws -> LoomOverlayProbeResponse
    ) {
        self.port = port
        self.requestTimeout = max(.milliseconds(1), requestTimeout)
        let maxPendingConnections = max(1, maxPendingConnections)
        self.maxPendingConnections = maxPendingConnections
        outstandingOperationLimiter = LoomOutstandingOperationLimiter(
            maximumConcurrentOperations: maxPendingConnections
        )
        self.payloadProvider = payloadProvider
    }

    package func start() async throws -> UInt16 {
        guard listener == nil else {
            return listener?.port?.rawValue ?? port
        }
        let requestedPort = port
        guard let endpointPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw LoomError.protocolError("Overlay probe port is invalid.")
        }

        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: false
        )
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.accept(connection: connection)
            }
        }
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuationBox.resume(returning: listener.port?.rawValue ?? requestedPort)
                case let .failed(error):
                    continuationBox.resume(throwing: error)
                case .cancelled:
                    continuationBox.resume(
                        throwing: LoomError.protocolError("Overlay probe listener cancelled.")
                    )
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

    private func accept(connection: NWConnection) async {
        guard pendingConnectionCount < maxPendingConnections else {
            LoomLogger.transport("Rejected overlay probe connection: admission limit reached")
            connection.cancel()
            return
        }
        pendingConnectionCount += 1
        do {
            try await withLoomThrowingTimeout(
                requestTimeout,
                onTimeout: {
                    connection.cancel()
                }
            ) { [weak self] in
                guard let self else { return }
                try await self.outstandingOperationLimiter.run {
                    await self.handle(connection: connection)
                }
            }
        } catch {
            connection.cancel()
        }
        pendingConnectionCount = max(0, pendingConnectionCount - 1)
    }

    private func handle(connection: NWConnection) async {
        let framedConnection = LoomFramedConnection(connection: connection)

        do {
            try await framedConnection.startAndAwaitReady(queue: .global(qos: .userInitiated))
            let requestData = try await framedConnection.readFrame(
                maxBytes: LoomMessageLimits.maxHelloFrameBytes
            )
            _ = try JSONDecoder().decode(LoomOverlayProbeRequest.self, from: requestData)
            let payload = try await payloadProvider()
            let responseData = try JSONEncoder().encode(payload)
            try await framedConnection.sendFrame(responseData)
        } catch {
            LoomLogger.debug(.transport, "Overlay probe failed: \(error.localizedDescription)")
        }

        connection.cancel()
    }
}

package enum LoomOverlayProbeClient {
    package static func probe(
        seed: LoomOverlaySeed,
        defaultPort: UInt16,
        timeout: Duration
    ) async throws -> LoomOverlayProbeResponse {
        let resolvedPort = seed.probePort ?? defaultPort
        guard let endpointPort = NWEndpoint.Port(rawValue: resolvedPort) else {
            throw LoomError.protocolError("Overlay probe port is invalid.")
        }

        let parameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: false
        )
        let connection = NWConnection(
            to: .hostPort(host: .init(seed.host), port: endpointPort),
            using: parameters
        )
        let framedConnection = LoomFramedConnection(connection: connection)

        do {
            let responseData = try await withLoomThrowingTimeout(
                timeout,
                onTimeout: {
                    connection.cancel()
                }
            ) {
                try await framedConnection.startAndAwaitReady(queue: .global(qos: .userInitiated))
                let request = LoomOverlayProbeRequest()
                try await framedConnection.sendFrame(JSONEncoder().encode(request))
                return try await framedConnection.readFrame(
                    maxBytes: LoomMessageLimits.maxHelloFrameBytes
                )
            }
            let response = try JSONDecoder().decode(LoomOverlayProbeResponse.self, from: responseData)
            connection.cancel()
            return response
        } catch {
            connection.cancel()
            throw error
        }
    }
}

#endif
