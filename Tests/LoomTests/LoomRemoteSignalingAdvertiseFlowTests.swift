//
//  LoomRemoteSignalingAdvertiseFlowTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/3/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Remote Signaling Advertise Flow", .serialized)
struct LoomRemoteSignalingAdvertiseFlowTests {
    @MainActor
    @Test("Advertise uses heartbeat only when session already exists")
    func advertiseUsesHeartbeatWhenSessionExists() async throws {
        let (client, requestedPaths) = makeClient(responses: [
            .json(statusCode: 200, body: ["ok": true]),
        ])

        try await client.advertisePeerSession(
            sessionID: "session-1",
            peerID: Self.peerID,
            acceptingConnections: true,
            peerCandidates: [],
            ttlSeconds: 360
        )

        #expect(requestedPaths() == ["/v1/session/heartbeat"])
    }

    @MainActor
    @Test("Advertise creates only when heartbeat reports missing session")
    func advertiseFallsBackToCreateAfterHeartbeat404() async throws {
        let (client, requestedPaths) = makeClient(responses: [
            .json(statusCode: 404, body: ["ok": false, "error": "session_not_found"]),
            .json(statusCode: 200, body: ["ok": true]),
        ])

        try await client.advertisePeerSession(
            sessionID: "session-2",
            peerID: Self.peerID,
            acceptingConnections: true,
            peerCandidates: [],
            ttlSeconds: 360
        )

        #expect(requestedPaths() == ["/v1/session/heartbeat", "/v1/session/create"])
    }

    @MainActor
    @Test("Advertise retries heartbeat when create races with another host")
    func advertiseRetriesHeartbeatAfterCreateConflict() async throws {
        let (client, requestedPaths) = makeClient(responses: [
            .json(statusCode: 404, body: ["ok": false, "error": "session_not_found"]),
            .json(statusCode: 409, body: ["ok": false, "error": "session_exists"]),
            .json(statusCode: 200, body: ["ok": true]),
        ])

        try await client.advertisePeerSession(
            sessionID: "session-3",
            peerID: Self.peerID,
            acceptingConnections: true,
            peerCandidates: [],
            ttlSeconds: 360
        )

        #expect(
            requestedPaths() == [
                "/v1/session/heartbeat",
                "/v1/session/create",
                "/v1/session/heartbeat",
            ]
        )
    }

    @MainActor
    private func makeClient(
        responses: [LoomRemoteSignalingMockResponse]
    ) -> (LoomRelayClient, @Sendable () -> [String]) {
        LoomRemoteSignalingMockURLProtocol.configure(responses)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LoomRemoteSignalingMockURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.remote-signaling.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let configuration = LoomRelayConfiguration(
            baseURL: URL(string: "https://loom-remote-signaling.test")!,
            requestTimeout: 5,
            appAuthentication: LoomRelayAppAuthentication(
                appID: "test-app-id",
                sharedSecret: "test-app-secret"
            )
        )
        let client = LoomRelayClient(
            configuration: configuration,
            identityManager: identityManager,
            urlSession: urlSession
        )
        return (client, { LoomRemoteSignalingMockURLProtocol.requestedPaths() })
    }

    private static let peerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

private struct LoomRemoteSignalingMockResponse {
    let statusCode: Int
    let bodyData: Data

    static func json(statusCode: Int, body: [String: Any]) -> LoomRemoteSignalingMockResponse {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return LoomRemoteSignalingMockResponse(statusCode: statusCode, bodyData: bodyData)
    }
}

private final class LoomRemoteSignalingMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResponses: [LoomRemoteSignalingMockResponse] = []
    private var paths: [String] = []

    func configure(responses: [LoomRemoteSignalingMockResponse]) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = responses
        paths.removeAll(keepingCapacity: true)
    }

    func dequeue(path: String) -> LoomRemoteSignalingMockResponse? {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
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

private final class LoomRemoteSignalingMockURLProtocol: URLProtocol {
    private static let state = LoomRemoteSignalingMockState()

    static func configure(_ responses: [LoomRemoteSignalingMockResponse]) {
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
        guard let response = Self.state.dequeue(path: url.path) else {
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
}
