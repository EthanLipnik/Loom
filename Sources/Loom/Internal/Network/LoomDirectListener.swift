//
//  LoomDirectListener.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import LoomNetworking

package typealias LoomDirectConnectionHandler = @Sendable (any LoomNetworkConnection) async -> Void

package protocol LoomDirectTransportListener: Sendable {
    func start(
        port: UInt16,
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16

    func stop() async
}

package actor LoomDirectListener: LoomDirectTransportListener {
    private let listener: any LoomNetworkListener
    private var acceptTask: Task<Void, Never>?

    package init(listener: any LoomNetworkListener) {
        self.listener = listener
    }

    package func start(
        port: UInt16 = 0,
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16 {
        let connectionStream = await listener.makeConnectionStream()
        acceptTask = Task { [listener] in
            for await connection in connectionStream {
                guard !Task.isCancelled else {
                    await connection.cancel()
                    break
                }
                await onConnection(connection)
            }
            if Task.isCancelled {
                await listener.cancel()
            }
        }

        do {
            return try await listener.start(port: port)
        } catch {
            acceptTask?.cancel()
            acceptTask = nil
            await listener.cancel()
            throw error
        }
    }

    package func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        await listener.cancel()
    }
}
