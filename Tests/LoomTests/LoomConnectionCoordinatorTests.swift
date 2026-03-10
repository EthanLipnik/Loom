//
//  LoomConnectionCoordinatorTests.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

@testable import Loom
import Network
import Testing

@Suite("Loom Connection Coordinator", .serialized)
struct LoomConnectionCoordinatorTests {
    @MainActor
    @Test("Local discovery plans advertised direct transports before falling back to relay")
    func localPlanUsesAdvertisedTransports() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredRemoteTransportOrder: [.quic, .tcp]
                )
            )
        )
        let coordinator = LoomConnectionCoordinator(node: node)
        let peer = LoomPeer(
            id: UUID(),
            name: "Nearby Mac",
            deviceType: .mac,
            endpoint: .hostPort(host: "127.0.0.1", port: 4444),
            advertisement: LoomPeerAdvertisement(
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: 4444),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: 5555),
                ]
            )
        )

        let plan = try await coordinator.makePlan(localPeer: peer)

        #expect(plan.targets.map(\.transportKind) == [.quic, .tcp])
        #expect(plan.targets.first?.endpoint == .hostPort(host: "127.0.0.1", port: 5555))
        #expect(plan.targets.last?.endpoint == .hostPort(host: "127.0.0.1", port: 4444))
    }

    @MainActor
    @Test("Local discovery prefers wired then Wi-Fi then AWDL when path hints are present")
    func localPlanPrefersConfiguredPathOrder() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredLocalPathOrder: [.wired, .wifi, .awdl, .other],
                    preferredRemoteTransportOrder: [.quic, .tcp]
                )
            )
        )
        let coordinator = LoomConnectionCoordinator(node: node)
        let peer = LoomPeer(
            id: UUID(),
            name: "Nearby Mac",
            deviceType: .mac,
            endpoint: .hostPort(host: "127.0.0.1", port: 4444),
            advertisement: LoomPeerAdvertisement(
                deviceType: .mac,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: 5555, pathKind: .awdl),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: 6666, pathKind: .wifi),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: 7777, pathKind: .wired),
                ]
            )
        )

        let plan = try await coordinator.makePlan(localPeer: peer)

        #expect(plan.targets.map(\.endpoint) == [
            .hostPort(host: "127.0.0.1", port: 7777),
            .hostPort(host: "127.0.0.1", port: 6666),
            .hostPort(host: "127.0.0.1", port: 5555),
        ])
    }

    @Test("Peer advertisements round-trip direct transport hints through TXT records")
    func advertisementRoundTripsDirectTransports() {
        let advertisement = LoomPeerAdvertisement(
            deviceID: UUID(),
            deviceType: .mac,
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .tcp, port: 4444, pathKind: .wired),
                LoomDirectTransportAdvertisement(transportKind: .quic, port: 4444, pathKind: .awdl),
            ],
            metadata: ["myapp.protocol": "1"]
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: advertisement.toTXTRecord())

        #expect(decoded.directTransports == advertisement.directTransports)
        #expect(decoded.metadata["myapp.protocol"] == "1")
    }

    @MainActor
    @Test("Raced local candidates return the fastest successful transport")
    func racedLocalCandidatesReturnFastestSuccess() async throws {
        try await LoomGlobalSinkTestLock.shared.runOnMainActor(reset: {
            await LoomInstrumentation.resetForTesting()
        }) {
            let instrumentationSink = ConnectionCoordinatorInstrumentationSink()
            _ = await LoomInstrumentation.addSink(instrumentationSink)
            let attemptRecorder = ConnectionAttemptRecorder()
            let node = LoomNode(
                configuration: LoomNetworkConfiguration(
                    directConnectionPolicy: LoomDirectConnectionPolicy(
                        preferredRemoteTransportOrder: [.quic, .tcp],
                        racesLocalCandidates: true,
                        racesRemoteCandidates: false
                    )
                )
            )
            let coordinator = LoomConnectionCoordinator(
                node: node,
                connector: { target, _ in
                    await attemptRecorder.record(target.transportKind)
                    switch target.transportKind {
                    case .quic:
                        try await Task.sleep(for: .milliseconds(250))
                        return makeCoordinatorTestSession(transportKind: .quic)
                    case .tcp:
                        try await Task.sleep(for: .milliseconds(25))
                        return makeCoordinatorTestSession(transportKind: .tcp)
                    }
                }
            )

            let session = try await coordinator.connect(
                hello: makeCoordinatorTestHello(),
                localPeer: makeCoordinatorTestPeer()
            )

            #expect(await session.transportKind == .tcp)
            #expect(await attemptRecorder.attempts() == [.quic, .tcp])
            #expect(await waitUntil {
                let events = await instrumentationSink.eventNames()
                return events.contains("loom.connection.race.localDiscovery.started.2") &&
                    events.contains("loom.connection.race.localDiscovery.selected.tcp") &&
                    events.contains("loom.connection.race.cancelled.localDiscovery.quic")
            })
        }
    }

    @MainActor
    @Test("Sequential local candidates keep preferred order when racing is disabled")
    func sequentialLocalCandidatesKeepPreferredOrder() async throws {
        let attemptRecorder = ConnectionAttemptRecorder()
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredRemoteTransportOrder: [.quic, .tcp],
                    racesLocalCandidates: false,
                    racesRemoteCandidates: false
                )
            )
        )
        let coordinator = LoomConnectionCoordinator(
            node: node,
            connector: { target, _ in
                await attemptRecorder.record(target.transportKind)
                switch target.transportKind {
                case .quic:
                    try await Task.sleep(for: .milliseconds(50))
                    return makeCoordinatorTestSession(transportKind: .quic)
                case .tcp:
                    try await Task.sleep(for: .milliseconds(5))
                    return makeCoordinatorTestSession(transportKind: .tcp)
                }
            }
        )

        let session = try await coordinator.connect(
            hello: makeCoordinatorTestHello(),
            localPeer: makeCoordinatorTestPeer()
        )

        #expect(await session.transportKind == .quic)
        #expect(await attemptRecorder.attempts() == [.quic])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

@MainActor
private func makeCoordinatorTestPeer() -> LoomPeer {
    LoomPeer(
        id: UUID(),
        name: "Nearby Mac",
        deviceType: .mac,
        endpoint: .hostPort(host: "127.0.0.1", port: 4444),
        advertisement: LoomPeerAdvertisement(
            deviceType: .mac,
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .tcp, port: 4444),
                LoomDirectTransportAdvertisement(transportKind: .quic, port: 5555),
            ]
        )
    )
}

private func makeCoordinatorTestHello() -> LoomSessionHelloRequest {
    LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Coordinator Test",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac)
    )
}

private func makeCoordinatorTestSession(
    transportKind: LoomTransportKind
) -> LoomAuthenticatedSession {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: 9)!,
        using: .tcp
    )
    return LoomAuthenticatedSession(
        rawSession: LoomSession(connection: connection),
        role: .initiator,
        transportKind: transportKind
    )
}

private actor ConnectionAttemptRecorder {
    private var recordedAttempts: [LoomTransportKind] = []

    func record(_ transportKind: LoomTransportKind) {
        recordedAttempts.append(transportKind)
    }

    func attempts() -> [LoomTransportKind] {
        recordedAttempts
    }
}

private actor ConnectionCoordinatorInstrumentationSink: LoomInstrumentationSink {
    private var events: [String] = []

    func record(event: LoomInstrumentationEvent) async {
        events.append(event.name)
    }

    func eventNames() -> [String] {
        events
    }
}
