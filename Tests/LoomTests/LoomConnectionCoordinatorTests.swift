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

    @MainActor
    @Test("Connection plans order nearby targets before overlay and relay targets")
    func connectionPlanOrdersNearbyThenOverlayThenRelay() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                enablePeerToPeer: false,
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredRemoteTransportOrder: [.quic, .tcp],
                    racesLocalCandidates: false,
                    racesRemoteCandidates: false
                )
            )
        )
        let (relayClient, _, _) = makeCoordinatorRelayClient(
            responses: [
                .json(
                    statusCode: 200,
                    body: [
                        "exists": true,
                        "remoteEnabled": true,
                        "peerCandidates": [
                            ["transport": "tcp", "address": "198.51.100.20", "port": 42020],
                        ],
                    ]
                ),
            ]
        )
        let coordinator = LoomConnectionCoordinator(
            node: node,
            relayClient: relayClient
        )

        let plan = try await coordinator.makePlan(
            localPeer: makeCoordinatorTestPeer(),
            overlayPeer: makeCoordinatorTestPeer(
                name: "Overlay Host",
                endpointHost: "overlay.internal",
                tcpPort: 4600,
                quicPort: 5600
            ),
            relaySessionID: "relay-session"
        )

        #expect(plan.targets.map(\.source) == [
            .localDiscovery,
            .localDiscovery,
            .overlayDirectory,
            .overlayDirectory,
            .relay,
        ])
    }

    @MainActor
    @Test("Relay fallback remains available when only overlay discovery succeeded")
    func relayFallbackIgnoresOverlayPresence() {
        let overlayPeer = makeCoordinatorTestPeer(
            name: "Overlay Host",
            endpointHost: "overlay.internal",
            tcpPort: 4600,
            quicPort: nil
        )

        #expect(
            LoomConnectionCoordinator.relayFallbackSessionID(
                advertisedRelaySessionID: "relay-session",
                localPeer: nil,
                overlayPeer: overlayPeer
            ) == "relay-session"
        )
        #expect(
            LoomConnectionCoordinator.relayFallbackSessionID(
                advertisedRelaySessionID: "relay-session",
                localPeer: makeCoordinatorTestPeer(),
                overlayPeer: overlayPeer
            ) == nil
        )
    }

    @MainActor
    @Test("Overlay connections succeed before relay candidates are attempted")
    func overlayConnectionsSkipRelayAttemptsOnSuccess() async throws {
        let (relayClient, requestedPaths, _) = makeCoordinatorRelayClient(
            responses: [
                .json(
                    statusCode: 200,
                    body: [
                        "exists": true,
                        "remoteEnabled": true,
                        "peerCandidates": [
                            ["transport": "tcp", "address": "198.51.100.21", "port": 42121],
                        ],
                    ]
                ),
            ]
        )
        let attemptRecorder = ConnectionAttemptRecorder()
        let instrumentationSink = ConnectionCoordinatorInstrumentationSink()

        try await LoomGlobalSinkTestLock.shared.runOnMainActor(reset: {
            await LoomInstrumentation.resetForTesting()
        }) {
            _ = await LoomInstrumentation.addSink(instrumentationSink)
            let coordinator = LoomConnectionCoordinator(
                node: LoomNode(
                    configuration: LoomNetworkConfiguration(
                        enablePeerToPeer: false,
                        directConnectionPolicy: LoomDirectConnectionPolicy(
                            preferredRemoteTransportOrder: [.quic, .tcp],
                            racesLocalCandidates: false,
                            racesRemoteCandidates: false
                        )
                    )
                ),
                relayClient: relayClient,
                connector: { target, _ in
                    await attemptRecorder.record(target.transportKind, source: target.source)
                    return makeCoordinatorTestSession(transportKind: target.transportKind)
                }
            )

            let session = try await coordinator.connect(
                hello: makeCoordinatorTestHello(),
                overlayPeer: makeCoordinatorTestPeer(
                    name: "Overlay Host",
                    endpointHost: "overlay.internal",
                    tcpPort: 4700,
                    quicPort: nil
                ),
                relaySessionID: "relay-session"
            )

            #expect(await session.transportKind == .tcp)
            #expect(await attemptRecorder.sources() == [.overlayDirectory])
            #expect(requestedPaths() == ["/v1/session/presence"])
            #expect(await waitUntil {
                let events = await instrumentationSink.eventNames()
                return events.contains("loom.connection.connected.overlayDirectory.tcp.unknown")
            })
        }
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
    makeCoordinatorTestPeer(
        name: "Nearby Mac",
        endpointHost: "127.0.0.1",
        tcpPort: 4444,
        quicPort: 5555
    )
}

@MainActor
private func makeCoordinatorTestPeer(
    name: String,
    endpointHost: String,
    tcpPort: UInt16,
    quicPort: UInt16?
) -> LoomPeer {
    LoomPeer(
        id: UUID(),
        name: name,
        deviceType: .mac,
        endpoint: .hostPort(host: .init(endpointHost), port: .init(rawValue: tcpPort)!),
        advertisement: LoomPeerAdvertisement(
            deviceType: .mac,
            directTransports: {
                var transports = [
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort),
                ]
                if let quicPort {
                    transports.append(
                        LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort)
                    )
                }
                return transports
            }()
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
    private var recordedSources: [LoomConnectionTargetSource] = []

    func record(_ transportKind: LoomTransportKind) {
        recordedAttempts.append(transportKind)
    }

    func record(_ transportKind: LoomTransportKind, source: LoomConnectionTargetSource) {
        recordedAttempts.append(transportKind)
        recordedSources.append(source)
    }

    func attempts() -> [LoomTransportKind] {
        recordedAttempts
    }

    func sources() -> [LoomConnectionTargetSource] {
        recordedSources
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

private struct CoordinatorRelayMockResponse {
    let statusCode: Int
    let bodyData: Data

    static func json(statusCode: Int, body: [String: Any]) -> CoordinatorRelayMockResponse {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return CoordinatorRelayMockResponse(statusCode: statusCode, bodyData: bodyData)
    }
}

private final class CoordinatorRelayMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResponses: [CoordinatorRelayMockResponse] = []
    private var paths: [String] = []
    private var bodies: [[String: Any]] = []

    func configure(responses: [CoordinatorRelayMockResponse]) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = responses
        paths.removeAll(keepingCapacity: true)
        bodies.removeAll(keepingCapacity: true)
    }

    func dequeue(path: String, body: [String: Any]?) -> CoordinatorRelayMockResponse? {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
        if let body {
            bodies.append(body)
        }
        guard !queuedResponses.isEmpty else {
            return nil
        }
        return queuedResponses.removeFirst()
    }

    func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private final class CoordinatorRelayMockURLProtocol: URLProtocol {
    private static let state = CoordinatorRelayMockState()

    static func configure(_ responses: [CoordinatorRelayMockResponse]) {
        state.configure(responses: responses)
    }

    static func requestedPaths() -> [String] {
        state.requestedPaths()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let requestBody: [String: Any]? = if let body = Self.requestBodyData(for: request) {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        } else {
            nil
        }
        guard let response = Self.state.dequeue(path: url.path, body: requestBody) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["content-type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.bodyData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer {
            stream.close()
        }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }
        var data = Data()

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            guard readCount > 0 else {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data.isEmpty ? nil : data
    }
}

@MainActor
private func makeCoordinatorRelayClient(
    responses: [CoordinatorRelayMockResponse]
) -> (LoomRelayClient, @Sendable () -> [String], URLSession) {
    CoordinatorRelayMockURLProtocol.configure(responses)
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [CoordinatorRelayMockURLProtocol.self]
    let urlSession = URLSession(configuration: sessionConfiguration)
    let client = LoomRelayClient(
        configuration: LoomRelayConfiguration(
            baseURL: URL(string: "https://loom-coordinator-relay.test")!,
            requestTimeout: 5,
            appAuthentication: LoomRelayAppAuthentication(
                appID: "test-app-id",
                sharedSecret: "test-app-secret"
            )
        ),
        identityManager: LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.coordinator-relay.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        ),
        urlSession: urlSession
    )
    return (
        client,
        { CoordinatorRelayMockURLProtocol.requestedPaths() },
        urlSession
    )
}
