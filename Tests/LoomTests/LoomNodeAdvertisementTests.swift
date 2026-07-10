//
//  LoomNodeAdvertisementTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/26/26.
//

@testable import Loom
import Foundation
import Network
import Testing

@Suite("Loom Node Advertisement")
struct LoomNodeAdvertisementTests {
    @MainActor
    @Test("Node rejects the removed QUIC direct transport")
    func nodeRejectsRemovedQUICTransport() throws {
        let node = LoomNode()
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: 9))
        )

        #expect(throws: LoomError.self) {
            try node.makeConnection(
                to: endpoint,
                using: .quic,
                enablePeerToPeer: false
            )
        }
    }

    @MainActor
    @Test("TCP and direct sessions share one active admission that releases at terminal state")
    func activeSessionAdmissionIsSharedAndTerminalBound() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(maximumActiveAuthenticatedSessions: 2)
        )
        let port = try #require(NWEndpoint.Port(rawValue: 9))
        let tcpSession = node.makeAuthenticatedSession(
            connection: .tcp(NWConnection(host: "127.0.0.1", port: port, using: .tcp)),
            role: .receiver
        )
        let directSession = node.makeAuthenticatedSession(
            connection: .udp(NWConnection(host: "127.0.0.1", port: port, using: .udp)),
            role: .receiver
        )

        #expect(await node.admitAuthenticatedSessionForTesting(tcpSession))
        node.configuration.maximumActiveAuthenticatedSessions = 1
        #expect(!(await node.admitAuthenticatedSessionForTesting(directSession)))
        #expect(await node.activeAuthenticatedSessionCountForTesting == 1)

        await tcpSession.cancel()
        let releaseDeadline = ContinuousClock.now + .seconds(1)
        while await node.activeAuthenticatedSessionCountForTesting != 0,
              ContinuousClock.now < releaseDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await node.activeAuthenticatedSessionCountForTesting == 0)
        #expect(await node.admitAuthenticatedSessionForTesting(directSession))
        await directSession.cancel()
    }

    @MainActor
    @Test("Node aggregate incoming budget spans multiple sessions")
    func nodeAggregateIncomingBudgetSpansSessions() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                maximumBufferedIncomingBytesPerStream: 10,
                maximumBufferedIncomingBytesPerSession: 10,
                maximumBufferedIncomingBytesPerNode: 12
            )
        )
        let port = try #require(NWEndpoint.Port(rawValue: 9))
        let first = node.makeAuthenticatedSession(
            connection: .tcp(NWConnection(host: "127.0.0.1", port: port, using: .tcp)),
            role: .receiver
        )
        try await first.injectOpenForTesting(streamID: 41)
        try await first.injectReliableDataForTesting(
            streamID: 41,
            payload: Data(repeating: 1, count: 6)
        )
        #expect(node.retainedIncomingBytesForTesting == 6)
        node.configuration.maximumBufferedIncomingBytesPerNode = 10
        let second = node.makeAuthenticatedSession(
            connection: .tcp(NWConnection(host: "127.0.0.1", port: port, using: .tcp)),
            role: .receiver
        )
        defer {
            Task {
                await first.cancel()
                await second.cancel()
            }
        }
        try await second.injectOpenForTesting(streamID: 41)
        await #expect(throws: LoomError.self) {
            try await second.injectReliableDataForTesting(
                streamID: 41,
                payload: Data(repeating: 2, count: 5)
            )
        }
        #expect(node.retainedIncomingBytesForTesting == 6)
        await first.cancel()
        #expect(node.retainedIncomingBytesForTesting == 0)
    }

    @MainActor
    @Test("TCP-only advertising publishes diagnostics")
    func tcpOnlyAdvertisingPublishesDiagnostics() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                enableBonjour: false,
                enablePeerToPeer: false,
                enabledDirectTransports: []
            ),
            identityManager: LoomIdentityManager(
                service: "loom.tests.advertising.\(UUID().uuidString)",
                synchronizable: false
            )
        )

        let deviceID = UUID()
        let ports = try await node.startAuthenticatedAdvertising(
            serviceName: "Test Host",
            helloProvider: {
                LoomSessionHelloRequest(
                    deviceID: deviceID,
                    deviceName: "Test Host",
                    deviceType: .mac,
                    advertisement: LoomPeerAdvertisement(
                        deviceID: deviceID,
                        deviceType: .mac
                    )
                )
            },
            onSession: { _ in }
        )

        #expect(node.advertisingDiagnostics.state == .advertising)
        #expect(node.advertisingDiagnostics.serviceName == "Test Host")
        #expect(node.advertisingDiagnostics.bonjourPort == nil)
        #expect(node.advertisingDiagnostics.directListenerPorts[.tcp] == ports[.tcp])
        #expect(node.advertisingDiagnostics.lastBonjourFailureDescription == nil)

        await node.stopAdvertising()
        #expect(node.advertisingDiagnostics.state == .idle)
    }

    @MainActor
    @Test("Restarting authenticated advertising closes every previous listener generation")
    func authenticatedAdvertisingRestartClosesPreviousGeneration() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                enableBonjour: false,
                enablePeerToPeer: false,
                enabledDirectTransports: []
            ),
            identityManager: LoomIdentityManager(
                service: "loom.tests.advertising.restart.\(UUID().uuidString)",
                synchronizable: false
            )
        )
        defer {
            Task { await node.stopAdvertising() }
        }

        let deviceID = UUID()
        let helloProvider: @Sendable () async throws -> LoomSessionHelloRequest = {
            LoomSessionHelloRequest(
                deviceID: deviceID,
                deviceName: "Restart Test Host",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement(
                    deviceID: deviceID,
                    deviceType: .mac
                )
            )
        }
        let firstPorts = try await node.startAuthenticatedAdvertising(
            serviceName: "Restart Test Host",
            helloProvider: helloProvider,
            onSession: { _ in }
        )
        let firstPort = try #require(firstPorts[.tcp])

        node.configuration.controlPort = 0
        let replacementPorts = try await node.startAuthenticatedAdvertising(
            serviceName: "Restart Test Host",
            helloProvider: helloProvider,
            onSession: { _ in }
        )
        let replacementPort = try #require(replacementPorts[.tcp])
        #expect(replacementPort != firstPort)
        #expect(!(await canConnectToNodeTestPort(firstPort)))

        await node.stopAdvertising()
        #expect(!(await canConnectToNodeTestPort(replacementPort)))
    }

    @Test("Bonjour advertiser recovery delay backs off and caps")
    func bonjourAdvertiserRecoveryDelayBacksOffAndCaps() {
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 1) == .seconds(1))
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 2) == .seconds(2))
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 5) == .seconds(16))
        #expect(LoomNode.bonjourAdvertisingRecoveryDelay(attempt: 10) == .seconds(30))
    }

    @Test("Advertisement leaves hostName unset when no explicit host name is provided")
    func advertisementLeavesHostNameUnsetWithoutExplicitValue() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )

        let updated = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [:],
            serviceName: "Mirage Host"
        )

        #expect(updated.hostName == nil)
    }

    @Test("Advertisement preserves an explicit host name when one is already present")
    func advertisementPreservesExplicitHostName() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac,
            hostName: "existing.local"
        )

        let updated = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [:],
            serviceName: "Mirage Host"
        )

        #expect(updated.hostName == "existing.local")
    }

    @Test("Initial authenticated Bonjour advertisement includes ready direct transports")
    func initialAuthenticatedBonjourAdvertisementIncludesReadyDirectTransports() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )

        let initial = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [
                .udp: 1234,
                .quic: 5678,
            ],
            serviceName: "Mirage Host"
        )

        #expect(Set(initial.directTransports.map(\.transportKind)) == [.udp, .quic])
        #expect(initial.directTransports.contains { $0.transportKind == .tcp } == false)
    }

    @Test("Bonjour TCP update preserves previously advertised direct transports")
    func bonjourTCPUpdatePreservesPreviouslyAdvertisedDirectTransports() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )
        let initial = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [
                .udp: 1234,
                .quic: 5678,
            ],
            serviceName: "Mirage Host"
        )

        let updated = LoomNode.advertisement(
            initial,
            withDirectTransportPorts: [
                .udp: 1234,
                .quic: 5678,
                .tcp: 9012,
            ],
            serviceName: "Mirage Host"
        )

        #expect(Set(updated.directTransports.map(\.transportKind)) == [.tcp, .udp, .quic])
        #expect(updated.directTransports.first { $0.transportKind == .udp }?.port == 1234)
        #expect(updated.directTransports.first { $0.transportKind == .quic }?.port == 5678)
        #expect(updated.directTransports.first { $0.transportKind == .tcp }?.port == 9012)
    }

    @Test("TCP-only Bonjour advertisement gains TCP after service port is known")
    func tcpOnlyBonjourAdvertisementGainsTCPAfterServicePortIsKnown() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac
        )

        let initial = LoomNode.advertisement(
            advertisement,
            withDirectTransportPorts: [:],
            serviceName: "Mirage Host"
        )
        let updated = LoomNode.advertisement(
            initial,
            withDirectTransportPorts: [.tcp: 9012],
            serviceName: "Mirage Host"
        )

        #expect(initial.directTransports.isEmpty)
        #expect(updated.directTransports.map(\.transportKind) == [.tcp])
        #expect(updated.directTransports.first?.port == 9012)
    }
}

private func canConnectToNodeTestPort(_ rawPort: UInt16) async -> Bool {
    guard let port = NWEndpoint.Port(rawValue: rawPort) else { return false }
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    defer { connection.cancel() }
    return (try? await withCheckedThrowingContinuation { continuation in
        let box = LoomNodeAdvertisementTestContinuationBox(continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.complete(.success(true))
            case .failed, .cancelled:
                box.complete(.success(false))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            box.complete(.success(false))
        }
    }) ?? false
}

private final class LoomNodeAdvertisementTestContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
