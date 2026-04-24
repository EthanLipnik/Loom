//
//  LoomOverlayProbe.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/11/26.
//

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
    private let payloadProvider: @Sendable () async throws -> LoomOverlayProbeResponse
    private var listener: NWListener?

    package init(
        port: UInt16,
        payloadProvider: @escaping @Sendable () async throws -> LoomOverlayProbeResponse
    ) {
        self.port = port
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
                await self.handle(connection: connection)
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
            let responseData = try await withThrowingTimeout(
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

private func withThrowingTimeout<T: Sendable>(
    _ timeout: Duration,
    onTimeout: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            onTimeout()
            throw LoomError.connectionFailed(CancellationError())
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
