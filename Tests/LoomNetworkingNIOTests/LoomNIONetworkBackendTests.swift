//
//  LoomNIONetworkBackendTests.swift
//  LoomNetworkingNIOTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking
import LoomNetworkingNIO
import Testing

@Suite("SwiftNIO Network Backend")
struct LoomNIONetworkBackendTests {
    @Test("Service endpoints require discovery resolution before direct connection")
    func serviceEndpointsRequireResolution() {
        let backend = LoomNIONetworkBackend()

        #expect(throws: LoomNetworkError.self) {
            _ = try backend.makeConnection(
                to: .service(
                    name: "Example",
                    type: "_loom._tcp",
                    domain: "local.",
                    interfaceName: nil
                ),
                using: .tcp,
                configuration: LoomNetworkConnectionConfiguration()
            )
        }
    }

    @Test(
        "TCP loopback preserves byte order in both directions",
        arguments: ["::1", "127.0.0.1"]
    )
    func tcpLoopback(host: LoomNetworkHost) async throws {
        let backend = LoomNIONetworkBackend()
        let listener = try backend.makeListener(
            using: .tcp,
            configuration: LoomNetworkListenerConfiguration()
        )
        let connections = await listener.makeConnectionStream()
        let port = try await listener.start(port: 0)
        let client = try backend.makeConnection(
            to: .hostPort(host: host, port: port),
            using: .tcp,
            configuration: LoomNetworkConnectionConfiguration()
        )

        do {
            try await client.start()
            let server = try await nextConnection(from: connections)
            try await server.start()

            try await client.send(Data("request".utf8))
            #expect(try await server.receive(maximumBytes: 64) == Data("request".utf8))

            try await server.send(Data("response".utf8))
            #expect(try await client.receive(maximumBytes: 64) == Data("response".utf8))

            await client.cancel()
            await server.cancel()
            await listener.cancel()
        } catch {
            await client.cancel()
            await listener.cancel()
            throw error
        }
    }

    @Test(
        "UDP listener demultiplexes a connected loopback flow",
        arguments: ["::1", "127.0.0.1"]
    )
    func udpLoopback(host: LoomNetworkHost) async throws {
        let backend = LoomNIONetworkBackend()
        let listener = try backend.makeListener(
            using: .udp,
            configuration: LoomNetworkListenerConfiguration()
        )
        let connections = await listener.makeConnectionStream()
        let port = try await listener.start(port: 0)
        let client = try backend.makeConnection(
            to: .hostPort(host: host, port: port),
            using: .udp,
            configuration: LoomNetworkConnectionConfiguration()
        )

        do {
            try await client.start()
            try await client.send(Data("first datagram".utf8))
            let server = try await nextConnection(from: connections)
            try await server.start()

            #expect(
                try await server.receive(maximumBytes: 64) == Data("first datagram".utf8)
            )
            try await server.send(Data("reply datagram".utf8))
            #expect(
                try await client.receive(maximumBytes: 64) == Data("reply datagram".utf8)
            )

            await client.cancel()
            await server.cancel()
            await listener.cancel()
        } catch {
            await client.cancel()
            await listener.cancel()
            throw error
        }
    }

    @Test("Cancelling a connection unblocks a pending receive")
    func cancellationUnblocksReceive() async throws {
        let backend = LoomNIONetworkBackend()
        let listener = try backend.makeListener(
            using: .tcp,
            configuration: LoomNetworkListenerConfiguration()
        )
        let connections = await listener.makeConnectionStream()
        let port = try await listener.start(port: 0)
        let client = try backend.makeConnection(
            to: .hostPort(host: "::1", port: port),
            using: .tcp,
            configuration: LoomNetworkConnectionConfiguration()
        )
        try await client.start()
        let server = try await nextConnection(from: connections)
        try await server.start()

        let receiveTask = Task {
            try await client.receive(maximumBytes: 64)
        }
        try await Task.sleep(for: .milliseconds(20))
        await client.cancel()

        do {
            _ = try await receiveTask.value
            Issue.record("Expected cancellation to fail the pending receive")
        } catch let error as LoomNetworkError {
            #expect(error.code == .cancelled)
        }

        await server.cancel()
        await listener.cancel()
    }

    @Test("Connection faults fail without leaving a live receive")
    func connectionFault() async throws {
        let backend = LoomNIONetworkBackend()
        let reservation = try backend.makeListener(
            using: .tcp,
            configuration: LoomNetworkListenerConfiguration()
        )
        let unusedPort = try await reservation.start(port: 0)
        await reservation.cancel()

        let connection = try backend.makeConnection(
            to: .hostPort(host: "::1", port: unusedPort),
            using: .tcp,
            configuration: LoomNetworkConnectionConfiguration()
        )
        do {
            try await connection.start()
            Issue.record("Expected a connection to the released port to fail")
            await connection.cancel()
        } catch let error as LoomNetworkError {
            #expect(error.code == .connectionRefused)
        }
    }
}

private enum LoomNIOTestTimeout: Error {
    case elapsed
    case streamFinished
}

private func nextConnection(
    from stream: AsyncStream<any LoomNetworkConnection>
) async throws -> any LoomNetworkConnection {
    try await withThrowingTaskGroup(of: (any LoomNetworkConnection).self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let connection = await iterator.next() else {
                throw LoomNIOTestTimeout.streamFinished
            }
            return connection
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw LoomNIOTestTimeout.elapsed
        }
        guard let connection = try await group.next() else {
            throw LoomNIOTestTimeout.streamFinished
        }
        group.cancelAll()
        return connection
    }
}
