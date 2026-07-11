//
//  LoomNIOTransportIntegrationTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

@testable import Loom
import Foundation
import LoomNetworking
import LoomNetworkingNIO
import Testing

@Suite("SwiftNIO Loom Transports", .serialized)
struct LoomNIOTransportIntegrationTests {
    @Test("Framed TCP transport preserves Loom wire framing over NIO loopback")
    func framedTCPLoopback() async throws {
        let pair = try await makeNIOPair(transportKind: .tcp)
        let client = LoomFramedConnection(connection: pair.client)
        let server = LoomFramedConnection(connection: pair.server)

        do {
            try await client.startAndAwaitReady(queue: .global())
            try await server.startAndAwaitReady(queue: .global())
            let payload = Data((0..<8_193).map { UInt8(truncatingIfNeeded: $0) })

            try await client.sendFrame(payload)
            #expect(try await server.readFrame(maxBytes: payload.count) == payload)

            await client.closeTransport()
            await server.closeTransport()
            await pair.listener.cancel()
        } catch {
            await client.closeTransport()
            await server.closeTransport()
            await pair.listener.cancel()
            throw error
        }
    }

    @Test("Reliable UDP transport preserves handshake bytes over NIO loopback")
    func reliableUDPLoopback() async throws {
        let pair = try await makeNIOPair(transportKind: .udp)
        let client = LoomReliableChannel(connection: pair.client)
        let server = LoomReliableChannel(connection: pair.server)

        do {
            try await client.startAndAwaitReady(queue: .global())
            try await server.startAndAwaitReady(queue: .global())
            let request = Data("nio reliable request".utf8)
            let response = Data("nio reliable response".utf8)

            try await client.sendHandshakeMessage(request)
            #expect(try await server.receiveHandshakeMessage(maxBytes: 256) == request)
            try await server.sendHandshakeMessage(response)
            #expect(try await client.receiveHandshakeMessage(maxBytes: 256) == response)

            await client.closeTransport()
            await server.closeTransport()
            await pair.listener.cancel()
        } catch {
            await client.closeTransport()
            await server.closeTransport()
            await pair.listener.cancel()
            throw error
        }
    }
}

private struct LoomNIOConnectionPair: Sendable {
    let client: any LoomNetworkConnection
    let server: any LoomNetworkConnection
    let listener: any LoomNetworkListener
}

private enum LoomNIOTransportTestError: Error {
    case listenerFinished
}

private func makeNIOPair(
    transportKind: LoomNetworking.LoomTransportKind
) async throws -> LoomNIOConnectionPair {
    let backend = LoomNIONetworkBackend()
    let listener = try backend.makeListener(
        using: transportKind,
        configuration: LoomNetworkListenerConfiguration()
    )
    let connections = await listener.makeConnectionStream()
    let port = try await listener.start(port: 0)
    let client = try backend.makeConnection(
        to: .hostPort(host: "::1", port: port),
        using: transportKind,
        configuration: LoomNetworkConnectionConfiguration()
    )
    try await client.start()

    if transportKind == .udp {
        // A datagram listener creates a logical peer connection on the first packet.
        // This deliberately invalid packet remains buffered and is ignored by the
        // reliable packet decoder after its receive loop starts.
        try await client.send(Data([0]))
    }

    let server = try await withLoomThrowingTimeout(.seconds(3)) {
        var iterator = connections.makeAsyncIterator()
        guard let connection = await iterator.next() else {
            throw LoomNIOTransportTestError.listenerFinished
        }
        return connection
    }
    return LoomNIOConnectionPair(client: client, server: server, listener: listener)
}
