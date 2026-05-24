//
//  LoomConnectionCoordinatorTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import Loom
import Network
import Testing

@Suite("Loom Connection Coordinator", .serialized)
struct LoomConnectionCoordinatorTests {
    @MainActor
    @Test("Local discovery plans advertised direct transports before falling back to remote signaling")
    func localPlanUsesAdvertisedTransports() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredTransportOrder: [.quic, .tcp]
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
    @Test("Local discovery host override preserves advertised transport ports")
    func localPlanUsesConfiguredHostOverride() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredTransportOrder: [.quic, .tcp],
                    localDiscoveryHostOverride: "127.0.0.1"
                )
            )
        )
        let coordinator = LoomConnectionCoordinator(node: node)
        let peer = LoomPeer(
            id: UUID(),
            name: "Nearby Mac",
            deviceType: .mac,
            endpoint: .hostPort(host: "10.0.0.164", port: 4444),
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
                    preferredTransportOrder: [.quic, .tcp]
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
            let attemptRecorder = ConnectionAttemptRecorder()
            let node = LoomNode(
                configuration: LoomNetworkConfiguration(
                    directConnectionPolicy: LoomDirectConnectionPolicy(
                        preferredTransportOrder: [.quic, .tcp],
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
                    case .udp:
                        try await Task.sleep(for: .milliseconds(10))
                        return makeCoordinatorTestSession(transportKind: .udp)
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
        }
    }

    @MainActor
    @Test("Sequential local candidates keep preferred order when racing is disabled")
    func sequentialLocalCandidatesKeepPreferredOrder() async throws {
        let attemptRecorder = ConnectionAttemptRecorder()
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredTransportOrder: [.quic, .tcp],
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
                case .udp:
                    try await Task.sleep(for: .milliseconds(2))
                    return makeCoordinatorTestSession(transportKind: .udp)
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
    @Test("Connection plans order nearby targets before overlay and remote signaling targets")
    func connectionPlanOrdersNearbyThenOverlayThenRemoteSignaling() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                enablePeerToPeer: false,
                directConnectionPolicy: LoomDirectConnectionPolicy(
                    preferredTransportOrder: [.quic, .tcp],
                    racesLocalCandidates: false,
                    racesRemoteCandidates: false
                )
            )
        )
        let (signalingClient, _, _) = makeCoordinatorSignalingClient(
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
            signalingClient: signalingClient
        )

        let plan = try await coordinator.makePlan(
            localPeer: makeCoordinatorTestPeer(),
            overlayPeer: makeCoordinatorTestPeer(
                name: "Overlay Host",
                endpointHost: "overlay.internal",
                tcpPort: 4600,
                quicPort: 5600
            ),
            signalingSessionID: "relay-session"
        )

        #expect(plan.targets.map(\.source) == [
            .localDiscovery,
            .localDiscovery,
            .overlayDirectory,
            .overlayDirectory,
            .remoteSignaling,
        ])
    }

    @MainActor
    @Test("Remote signaling fallback remains available when no local peer was found")
    func signalingFallbackRequiresMissingLocalPeer() {
        #expect(
            LoomConnectionCoordinator.signalingFallbackSessionID(
                advertisedSignalingSessionID: "relay-session",
                localPeer: nil
            ) == "relay-session"
        )
        #expect(
            LoomConnectionCoordinator.signalingFallbackSessionID(
                advertisedSignalingSessionID: "relay-session",
                localPeer: makeCoordinatorTestPeer()
            ) == nil
        )
    }

    @MainActor
    @Test("Overlay connections succeed before remote signaling candidates are attempted")
    func overlayConnectionsSkipRemoteSignalingAttemptsOnSuccess() async throws {
        let (signalingClient, requestedPaths, _) = makeCoordinatorSignalingClient(
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
                            preferredTransportOrder: [.quic, .tcp],
                            racesLocalCandidates: false,
                            racesRemoteCandidates: false
                        )
                    )
                ),
                signalingClient: signalingClient,
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
                signalingSessionID: "relay-session"
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
    if transportKind == .quic {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 9)!)
        let connection = try! LoomQUICTransportFactory.makeConnection(
            to: endpoint,
            enablePeerToPeer: false,
            requiredInterface: nil,
            requiredInterfaceType: nil,
            requiredLocalPort: nil,
            quicALPN: ["loom"],
            serviceClass: .interactiveVideo
        )
        return LoomAuthenticatedSession(
            connection: .quic(connection),
            role: .initiator
        )
    }

    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: 9)!,
        using: transportKind == .tcp ? .tcp : .udp
    )
    let loomConnection: LoomConnection = transportKind == .tcp ? .tcp(connection) : .udp(connection)
    return LoomAuthenticatedSession(
        connection: loomConnection,
        role: .initiator
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

private struct CoordinatorSignalingMockResponse {
    let statusCode: Int
    let bodyData: Data

    static func json(statusCode: Int, body: [String: Any]) -> CoordinatorSignalingMockResponse {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return CoordinatorSignalingMockResponse(statusCode: statusCode, bodyData: bodyData)
    }
}

private final class CoordinatorSignalingMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResponses: [CoordinatorSignalingMockResponse] = []
    private var paths: [String] = []
    private var bodies: [[String: Any]] = []

    func configure(responses: [CoordinatorSignalingMockResponse]) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = responses
        paths.removeAll(keepingCapacity: true)
        bodies.removeAll(keepingCapacity: true)
    }

    func dequeue(path: String, body: [String: Any]?) -> CoordinatorSignalingMockResponse? {
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

private final class CoordinatorSignalingMockURLProtocol: URLProtocol {
    private static let state = CoordinatorSignalingMockState()

    static func configure(_ responses: [CoordinatorSignalingMockResponse]) {
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
private func makeCoordinatorSignalingClient(
    responses: [CoordinatorSignalingMockResponse]
) -> (LoomRemoteSignalingClient, @Sendable () -> [String], URLSession) {
    CoordinatorSignalingMockURLProtocol.configure(responses)
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [CoordinatorSignalingMockURLProtocol.self]
    let urlSession = URLSession(configuration: sessionConfiguration)
    let client = LoomRemoteSignalingClient(
        configuration: LoomRemoteSignalingConfiguration(
            baseURL: URL(string: "https://loom-coordinator-signaling.test")!,
            requestTimeout: 5,
            appAuthentication: LoomRemoteSignalingAppAuthentication(
                appID: "test-app-id",
                sharedSecret: "test-app-secret"
            )
        ),
        identityManager: LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.coordinator-signaling.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        ),
        urlSession: urlSession
    )
    return (
        client,
        { CoordinatorSignalingMockURLProtocol.requestedPaths() },
        urlSession
    )
}
