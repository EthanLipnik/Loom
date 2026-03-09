//
//  LoomRelayClient.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Signed Cloudflare signaling client for remote session presence and peer advertisements.
//

import CryptoKit
import Foundation

/// Additional app-scoped authentication for signaling requests.
public struct LoomRelayAppAuthentication: Sendable {
    public let appID: String
    public let sharedSecret: String

    /// Creates app-scoped credentials used to sign Worker requests.
    ///
    /// - Parameters:
    ///   - appID: Public application identifier expected by signaling.
    ///   - sharedSecret: Shared secret used for HMAC request authentication.
    public init(appID: String, sharedSecret: String) {
        self.appID = appID
        self.sharedSecret = sharedSecret
    }
}

/// Configuration for the remote signaling service endpoint.
public struct LoomRelayConfiguration: Sendable {
    public let baseURL: URL
    public let requestTimeout: TimeInterval
    public let appAuthentication: LoomRelayAppAuthentication
    public let headerPrefix: String

    /// Creates signaling client configuration.
    ///
    /// - Parameters:
    ///   - baseURL: Worker base URL used for all signaling endpoints.
    ///   - requestTimeout: Per-request URLSession timeout in seconds.
    ///   - appAuthentication: App-level authentication material.
    public init(
        baseURL: URL,
        requestTimeout: TimeInterval = 5,
        appAuthentication: LoomRelayAppAuthentication,
        headerPrefix: String = "x-loom"
    ) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.appAuthentication = appAuthentication
        self.headerPrefix = Self.normalizedHeaderPrefix(headerPrefix)
    }

    /// Placeholder configuration for consumers that have not wired an app-owned endpoint.
    ///
    /// App targets should provide an explicit base URL for their own signaling service.
    public static var `default`: LoomRelayConfiguration {
        LoomRelayConfiguration(
            baseURL: URL(string: "https://example.invalid") ?? URL(fileURLWithPath: "/"),
            requestTimeout: 5,
            appAuthentication: LoomRelayAppAuthentication(
                appID: "invalid",
                sharedSecret: "invalid"
            ),
            headerPrefix: "x-loom"
        )
    }

    private static func normalizedHeaderPrefix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "x-loom" : trimmed
    }
}

/// Transport type for a remote connectivity candidate.
public enum LoomRelayCandidateTransport: String, Sendable, Codable {
    case quic
}

/// Remote endpoint candidate published by signaling.
public struct LoomRelayCandidate: Sendable, Codable, Hashable {
    public let transport: LoomRelayCandidateTransport
    public let address: String
    public let port: UInt16

    /// Creates a remote peer candidate.
    ///
    /// - Parameters:
    ///   - transport: Transport protocol used for direct connection.
    ///   - address: Candidate hostname or IP.
    ///   - port: Candidate listening port.
    public init(
        transport: LoomRelayCandidateTransport,
        address: String,
        port: UInt16
    ) {
        self.transport = transport
        self.address = address
        self.port = port
    }
}

/// Presence state returned by remote signaling.
public struct LoomRelayPresenceStatus: Sendable {
    public let exists: Bool
    public let acceptingConnections: Bool
    public let peerCandidates: [LoomRelayCandidate]
    public let lockedToParticipantKeyID: String?
    public let expiresAt: Date?
    public let lastPeerSeen: Date?
    public let lastParticipantSeen: Date?

    /// Creates a remote presence snapshot.
    ///
    /// - Parameters:
    ///   - exists: Whether the session exists in signaling.
    ///   - acceptingConnections: Whether the publishing peer currently accepts joins.
    ///   - peerCandidates: Candidates currently published by peer heartbeats.
    ///   - lockedToParticipantKeyID: Optional current lock owner identity key.
    ///   - expiresAt: Session expiry timestamp.
    ///   - lastPeerSeen: Last successful peer heartbeat time.
    ///   - lastParticipantSeen: Last successful participant join/heartbeat time.
    public init(
        exists: Bool,
        acceptingConnections: Bool,
        peerCandidates: [LoomRelayCandidate] = [],
        lockedToParticipantKeyID: String? = nil,
        expiresAt: Date? = nil,
        lastPeerSeen: Date? = nil,
        lastParticipantSeen: Date? = nil
    ) {
        self.exists = exists
        self.acceptingConnections = acceptingConnections
        self.peerCandidates = peerCandidates
        self.lockedToParticipantKeyID = lockedToParticipantKeyID
        self.expiresAt = expiresAt
        self.lastPeerSeen = lastPeerSeen
        self.lastParticipantSeen = lastParticipantSeen
    }
}

/// Remote signaling errors.
public enum LoomRelayError: LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case invalidPayload
    case http(statusCode: Int, errorCode: String?, detail: String?)

    /// Human-readable error text for UI and diagnostics.
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Remote signaling configuration is invalid"
        case .invalidResponse:
            "Remote signaling returned an invalid response"
        case .invalidPayload:
            "Remote signaling returned an invalid payload"
        case let .http(statusCode, errorCode, detail):
            if let errorCode, let detail {
                "Remote signaling error (\(statusCode)): \(errorCode) - \(detail)"
            } else if let errorCode {
                "Remote signaling error (\(statusCode)): \(errorCode)"
            } else {
                "Remote signaling request failed with status \(statusCode)"
            }
        }
    }

    /// True when signaling request credentials are rejected as unauthorized.
    public var isAuthenticationFailure: Bool {
        guard case let .http(statusCode, _, _) = self else { return false }
        return statusCode == 401 || statusCode == 403
    }

    /// True when retrying with the same configuration will not recover.
    public var isPermanentConfigurationFailure: Bool {
        if case .invalidConfiguration = self {
            return true
        }
        return isAuthenticationFailure
    }
}

/// Signed signaling API wrapper used by peer and participant remote coordination.
@MainActor
public final class LoomRelayClient {
    private let configuration: LoomRelayConfiguration
    private let identityManager: LoomIdentityManager
    private let urlSession: URLSession

    /// Creates a signed remote signaling client.
    ///
    /// - Parameters:
    ///   - configuration: Endpoint and request-signing configuration.
    ///   - identityManager: Identity provider used for key-based request signatures.
    ///   - urlSession: Session used for HTTP requests.
    public init(
        configuration: LoomRelayConfiguration,
        identityManager: LoomIdentityManager = .shared,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.identityManager = identityManager
        self.urlSession = urlSession
    }

    /// Ensures a peer session is advertised in signaling.
    ///
    /// This refreshes liveness through heartbeat first, then creates only if
    /// signaling reports the session is missing.
    /// - Parameters:
    ///   - sessionID: Signaling session identifier.
    ///   - peerID: Publishing peer device identifier.
    ///   - acceptingConnections: Whether the peer currently allows remote join.
    ///   - peerCandidates: Direct-connect candidates to publish.
    ///   - ttlSeconds: Session time-to-live used by signaling.
    ///
    /// - Note: The client retries heartbeat once if a concurrent peer create
    ///   races and returns `session_exists`.
    public func advertisePeerSession(
        sessionID: String,
        peerID: UUID,
        acceptingConnections: Bool,
        peerCandidates: [LoomRelayCandidate],
        ttlSeconds: Int = 360
    )
    async throws {
        do {
            try await peerHeartbeat(
                sessionID: sessionID,
                acceptingConnections: acceptingConnections,
                peerCandidates: peerCandidates,
                ttlSeconds: ttlSeconds
            )
            return
        } catch let error as LoomRelayError {
            guard case let .http(statusCode, errorCode, _) = error,
                  statusCode == 404,
                  errorCode == "session_not_found" else {
                throw error
            }
        }

        do {
            try await createPeerSession(
                sessionID: sessionID,
                peerID: peerID,
                acceptingConnections: acceptingConnections,
                peerCandidates: peerCandidates,
                ttlSeconds: ttlSeconds
            )
        } catch let error as LoomRelayError {
            if case let .http(_, errorCode, _) = error, errorCode == "session_exists" {
                try await peerHeartbeat(
                    sessionID: sessionID,
                    acceptingConnections: acceptingConnections,
                    peerCandidates: peerCandidates,
                    ttlSeconds: ttlSeconds
                )
                return
            }
            throw error
        }
    }

    /// Sends a peer heartbeat to maintain presence.
    ///
    /// Call this periodically while the peer listener is active.
    public func peerHeartbeat(
        sessionID: String,
        acceptingConnections: Bool? = nil,
        peerCandidates: [LoomRelayCandidate]? = nil,
        ttlSeconds: Int? = nil
    )
    async throws {
        var body: [String: Any] = ["role": "host"]
        if let acceptingConnections {
            body["remoteEnabled"] = acceptingConnections
        }
        if let peerCandidates {
            body["hostCandidates"] = encodeCandidates(peerCandidates)
        }
        if let ttlSeconds {
            body["ttlSeconds"] = ttlSeconds
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/heartbeat",
            bodyData: bodyData
        )
    }

    /// Closes a peer signaling session.
    ///
    /// Use this when the peer stops remote listening or shuts down.
    public func closePeerSession(sessionID: String) async throws {
        let body = ["role": "host"]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/close",
            bodyData: bodyData
        )
    }

    /// Joins a peer session and reserves the single-participant signaling lock.
    ///
    /// - Parameter sessionID: Session identifier to join.
    public func joinSession(sessionID: String) async throws {
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/join",
            bodyData: Data("{}".utf8)
        )
    }

    /// Releases a joined participant reservation for a session.
    ///
    /// - Parameter sessionID: Session identifier to release.
    public func leaveSession(sessionID: String) async throws {
        let body: [String: Any] = ["role": "client"]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/close",
            bodyData: bodyData
        )
    }

    /// Fetches remote presence state for a peer session.
    ///
    /// - Parameter sessionID: Session identifier to query.
    /// - Returns: Snapshot describing session existence, lock ownership, and candidate metadata.
    ///
    /// Example:
    /// ```swift
    /// let presence = try await client.fetchPresence(sessionID: sessionID)
    /// guard presence.exists, presence.acceptingConnections else { return }
    /// let candidates = presence.peerCandidates
    /// ```
    public func fetchPresence(sessionID: String) async throws -> LoomRelayPresenceStatus {
        let (_, data) = try await sendSignedRequest(
            sessionID: sessionID,
            method: "GET",
            path: "/v1/session/presence",
            bodyData: nil
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoomRelayError.invalidPayload
        }
        let exists = object["exists"] as? Bool ?? false
        return LoomRelayPresenceStatus(
            exists: exists,
            acceptingConnections: object["remoteEnabled"] as? Bool ?? object["acceptingConnections"] as? Bool ?? false,
            peerCandidates: parseCandidates(object["peerCandidates"] ?? object["hostCandidates"]),
            lockedToParticipantKeyID: object["lockedToParticipantKeyID"] as? String ?? object["lockedToClientKeyID"] as? String,
            expiresAt: dateFromMilliseconds(object["expiresAtMs"]),
            lastPeerSeen: dateFromMilliseconds(object["lastPeerSeenMs"] ?? object["lastHostSeenMs"]),
            lastParticipantSeen: dateFromMilliseconds(object["lastParticipantSeenMs"] ?? object["lastClientSeenMs"])
        )
    }

    private func createPeerSession(
        sessionID: String,
        peerID: UUID,
        acceptingConnections: Bool,
        peerCandidates: [LoomRelayCandidate],
        ttlSeconds: Int
    )
    async throws {
        let body: [String: Any] = [
            "hostID": peerID.uuidString.lowercased(),
            "ttlSeconds": ttlSeconds,
            "remoteEnabled": acceptingConnections,
            "hostCandidates": encodeCandidates(peerCandidates),
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/create",
            bodyData: bodyData
        )
    }

    private func sendSignedRequest(
        sessionID: String,
        method: String,
        path: String,
        bodyData: Data?
    )
    async throws -> (HTTPURLResponse, Data) {
        guard configuration.baseURL.scheme == "https" else {
            throw LoomRelayError.invalidConfiguration
        }
        let identity = try identityManager.currentIdentity()
        let nonce = UUID().uuidString.lowercased()
        let timestampMs = LoomIdentitySigning.currentTimestampMs()
        let bodyHash = Self.sha256Hex(bodyData ?? Data("-".utf8))
        let appAuthentication = configuration.appAuthentication
        LoomLogger.relay(
            "Remote signaling request \(method.uppercased()) \(path) session=\(sessionID) keyID=\(identity.keyID) bodyBytes=\(bodyData?.count ?? 0)"
        )
        let appAuthPayload = Self.appAuthPayload(
            method: method,
            path: path,
            bodySHA256: bodyHash,
            appID: appAuthentication.appID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let appSignature = Self.hmacSHA256Base64(
            payload: appAuthPayload,
            secret: appAuthentication.sharedSecret
        )
        let payload = try LoomIdentitySigning.workerRequestPayload(
            method: method,
            path: path,
            bodySHA256: bodyHash,
            keyID: identity.keyID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let signature = try identityManager.sign(payload)

        let url = configuration.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeout
        let headerPrefix = configuration.headerPrefix
        request.setValue(sessionID, forHTTPHeaderField: "\(headerPrefix)-session-id")
        request.setValue(appAuthentication.appID, forHTTPHeaderField: "\(headerPrefix)-app-id")
        request.setValue("\(timestampMs)", forHTTPHeaderField: "\(headerPrefix)-app-timestamp-ms")
        request.setValue(nonce, forHTTPHeaderField: "\(headerPrefix)-app-nonce")
        request.setValue(appSignature, forHTTPHeaderField: "\(headerPrefix)-app-signature")
        request.setValue(identity.keyID, forHTTPHeaderField: "\(headerPrefix)-key-id")
        request.setValue(identity.publicKey.base64EncodedString(), forHTTPHeaderField: "\(headerPrefix)-public-key")
        request.setValue("\(timestampMs)", forHTTPHeaderField: "\(headerPrefix)-timestamp-ms")
        request.setValue(nonce, forHTTPHeaderField: "\(headerPrefix)-nonce")
        request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "\(headerPrefix)-signature")
        request.setValue(bodyHash, forHTTPHeaderField: "\(headerPrefix)-body-sha256")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            LoomLogger.error(.relay, "Remote signaling invalid response for \(method.uppercased()) \(path)")
            throw LoomRelayError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            let parsed = parseErrorPayload(data)
            LoomLogger.debug(.relay,
                "Remote signaling HTTP \(http.statusCode) \(method.uppercased()) \(path) error=\(parsed.errorCode ?? "none") detail=\(parsed.detail ?? "none")"
            )
            throw LoomRelayError.http(
                statusCode: http.statusCode,
                errorCode: parsed.errorCode,
                detail: parsed.detail
            )
        }
        LoomLogger.relay(
            "Remote signaling success \(method.uppercased()) \(path) status=\(http.statusCode) bytes=\(data.count)"
        )

        return (http, data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    private static func appAuthPayload(
        method: String,
        path: String,
        bodySHA256: String,
        appID: String,
        timestampMs: Int64,
        nonce: String
    ) -> Data {
        let fields = [
            ("type", "worker-app-auth-v1"),
            ("method", method.uppercased()),
            ("path", path),
            ("bodySHA256", bodySHA256),
            ("appID", appID),
            ("timestampMs", "\(timestampMs)"),
            ("nonce", nonce),
        ]
            .sorted { lhs, rhs in
                lhs.0 < rhs.0
            }
            .map { key, value in
                "\(key)=\(value)"
            }
            .joined(separator: "\n")
        return Data(fields.utf8)
    }

    private static func hmacSHA256Base64(payload: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(signature).base64EncodedString()
    }

    private func encodeCandidates(_ candidates: [LoomRelayCandidate]) -> [[String: Any]] {
        candidates.map { candidate in
            [
                "transport": candidate.transport.rawValue,
                "address": candidate.address,
                "port": Int(candidate.port),
            ]
        }
    }
}

private func parseErrorPayload(_ data: Data) -> (errorCode: String?, detail: String?) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (nil, nil)
    }
    return (
        object["error"] as? String,
        object["detail"] as? String
    )
}

private func dateFromMilliseconds(_ rawValue: Any?) -> Date? {
    if let value = rawValue as? Int {
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }
    if let value = rawValue as? Int64 {
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }
    if let value = rawValue as? Double {
        return Date(timeIntervalSince1970: value / 1000)
    }
    return nil
}

private func parseCandidates(_ rawValue: Any?) -> [LoomRelayCandidate] {
    guard let array = rawValue as? [[String: Any]] else {
        return []
    }
    return array.compactMap { candidateObject in
        guard let transportRaw = candidateObject["transport"] as? String,
              let transport = LoomRelayCandidateTransport(rawValue: transportRaw),
              let address = candidateObject["address"] as? String else {
            return nil
        }

        if let intPort = candidateObject["port"] as? Int,
           let port = UInt16(exactly: intPort) {
            return LoomRelayCandidate(
                transport: transport,
                address: address,
                port: port
            )
        }

        if let int64Port = candidateObject["port"] as? Int64,
           let port = UInt16(exactly: int64Port) {
            return LoomRelayCandidate(
                transport: transport,
                address: address,
                port: port
            )
        }

        return nil
    }
}
