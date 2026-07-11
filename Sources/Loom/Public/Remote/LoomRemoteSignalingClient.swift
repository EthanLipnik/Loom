//
//  LoomRemoteSignalingClient.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Signed Cloudflare signaling client for remote session presence and peer advertisements.
//

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Network)
import Foundation

/// Additional app-scoped authentication for signaling requests.
public struct LoomRemoteSignalingAppAuthentication: Sendable {
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
public struct LoomRemoteSignalingConfiguration: Sendable {
    public let baseURL: URL
    public let requestTimeout: TimeInterval
    public let appAuthentication: LoomRemoteSignalingAppAuthentication
    public let headerPrefix: String

    /// Creates signaling client configuration.
    ///
    /// - Parameters:
    ///   - baseURL: Worker base URL used for all signaling endpoints.
    ///   - requestTimeout: Per-request URLSession timeout in seconds.
    ///   - appAuthentication: App-level authentication material.
    ///   - headerPrefix: Lowercased HTTP header prefix used for signed request metadata.
    public init(
        baseURL: URL,
        requestTimeout: TimeInterval = 5,
        appAuthentication: LoomRemoteSignalingAppAuthentication,
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
    public static var `default`: LoomRemoteSignalingConfiguration {
        LoomRemoteSignalingConfiguration(
            baseURL: URL(string: "https://example.invalid") ?? URL(fileURLWithPath: "/"),
            requestTimeout: 5,
            appAuthentication: LoomRemoteSignalingAppAuthentication(
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

/// Remote endpoint candidate published by signaling.
public struct LoomRemoteCandidate: Sendable, Codable, Hashable {
    public let transport: LoomTransportKind
    public let address: String
    public let port: UInt16

    /// Creates a remote peer candidate.
    ///
    /// - Parameters:
    ///   - transport: Transport protocol used for direct connection.
    ///   - address: Candidate hostname or IP.
    ///   - port: Candidate listening port.
    public init(
        transport: LoomTransportKind,
        address: String,
        port: UInt16
    ) {
        self.transport = transport
        self.address = address
        self.port = port
    }
}

/// Presence state returned by remote signaling.
public struct LoomRemotePresenceStatus: Sendable {
    public let exists: Bool
    public let acceptingConnections: Bool
    public let advertisement: LoomPeerAdvertisement?
    public let peerCandidates: [LoomRemoteCandidate]
    public let clientCandidates: [LoomRemoteCandidate]
    public let lockedToParticipantKeyID: String?
    public let expiresAt: Date?
    public let lastPeerSeen: Date?
    public let lastParticipantSeen: Date?

    /// Creates a remote presence snapshot.
    ///
    /// - Parameters:
    ///   - exists: Whether the session exists in signaling.
    ///   - acceptingConnections: Whether the publishing peer currently accepts joins.
    ///   - advertisement: Optional peer advertisement snapshot currently published for the session.
    ///   - peerCandidates: Candidates currently published by peer heartbeats.
    ///   - lockedToParticipantKeyID: Optional current lock owner identity key.
    ///   - expiresAt: Session expiry timestamp.
    ///   - lastPeerSeen: Last successful peer heartbeat time.
    ///   - lastParticipantSeen: Last successful participant join/heartbeat time.
    public init(
        exists: Bool,
        acceptingConnections: Bool,
        advertisement: LoomPeerAdvertisement? = nil,
        peerCandidates: [LoomRemoteCandidate] = [],
        clientCandidates: [LoomRemoteCandidate] = [],
        lockedToParticipantKeyID: String? = nil,
        expiresAt: Date? = nil,
        lastPeerSeen: Date? = nil,
        lastParticipantSeen: Date? = nil
    ) {
        self.exists = exists
        self.acceptingConnections = acceptingConnections
        self.advertisement = advertisement
        self.peerCandidates = peerCandidates
        self.clientCandidates = clientCandidates
        self.lockedToParticipantKeyID = lockedToParticipantKeyID
        self.expiresAt = expiresAt
        self.lastPeerSeen = lastPeerSeen
        self.lastParticipantSeen = lastParticipantSeen
    }
}

/// Remote signaling errors.
public enum LoomRemoteSignalingError: LocalizedError, Sendable {
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
public final class LoomRemoteSignalingClient {
    private let configuration: LoomRemoteSignalingConfiguration
    private let identityManager: LoomIdentityManager
    private let urlSession: URLSession

    /// Creates a signed remote signaling client.
    ///
    /// - Parameters:
    ///   - configuration: Endpoint and request-signing configuration.
    ///   - identityManager: Identity provider used for key-based request signatures.
    ///   - urlSession: Session used for HTTP requests.
    public init(
        configuration: LoomRemoteSignalingConfiguration,
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
    ///   - advertisement: Optional peer advertisement snapshot to publish alongside presence.
    ///   - peerCandidates: Direct-connect candidates to publish.
    ///   - ttlSeconds: Session time-to-live used by signaling.
    ///
    /// - Note: The client retries heartbeat once if a concurrent peer create
    ///   races and returns `session_exists`.
    @discardableResult
    public func advertisePeerSession(
        sessionID: String,
        peerID: UUID,
        acceptingConnections: Bool,
        peerCandidates: [LoomRemoteCandidate],
        advertisement: LoomPeerAdvertisement? = nil,
        ttlSeconds: Int = 360
    )
    async throws -> HeartbeatResult {
        do {
            return try await peerHeartbeat(
                sessionID: sessionID,
                acceptingConnections: acceptingConnections,
                peerCandidates: peerCandidates,
                advertisement: advertisement,
                ttlSeconds: ttlSeconds
            )
        } catch let error as LoomRemoteSignalingError {
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
                advertisement: advertisement,
                ttlSeconds: ttlSeconds
            )
        } catch let error as LoomRemoteSignalingError {
            if case let .http(_, errorCode, _) = error, errorCode == "session_exists" {
                return try await peerHeartbeat(
                    sessionID: sessionID,
                    acceptingConnections: acceptingConnections,
                    peerCandidates: peerCandidates,
                    advertisement: advertisement,
                    ttlSeconds: ttlSeconds
                )
            }
            throw error
        }
        return HeartbeatResult(clientCandidates: [])
    }

    /// Sends a peer heartbeat to maintain presence.
    ///
    /// Call this periodically while the peer listener is active.
    /// Result returned from a heartbeat request, including client candidates for hole-punching.
    public struct HeartbeatResult: Sendable {
        public let clientCandidates: [LoomRemoteCandidate]
    }

    @discardableResult
    public func peerHeartbeat(
        sessionID: String,
        acceptingConnections: Bool? = nil,
        peerCandidates: [LoomRemoteCandidate]? = nil,
        advertisement: LoomPeerAdvertisement? = nil,
        ttlSeconds: Int? = nil
    )
    async throws -> HeartbeatResult {
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
        if let advertisementBlob = encodeAdvertisementBlob(advertisement) {
            body["advertisementBlob"] = advertisementBlob
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (_, responseData) = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/heartbeat",
            bodyData: bodyData
        )
        let object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
        return HeartbeatResult(clientCandidates: parseCandidates(object["clientCandidates"]))
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
    /// - Parameters:
    ///   - sessionID: Session identifier to join.
    ///   - clientCandidates: STUN-discovered endpoints the host can use for hole-punching.
    public func joinSession(
        sessionID: String,
        clientCandidates: [LoomRemoteCandidate] = []
    ) async throws {
        var body: [String: Any] = [:]
        if !clientCandidates.isEmpty {
            body["clientCandidates"] = clientCandidates.map { candidate in
                [
                    "transport": candidate.transport.rawValue,
                    "address": candidate.address,
                    "port": candidate.port,
                ] as [String: Any]
            }
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/join",
            bodyData: bodyData
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

    /// Lightweight read-only check for whether a client has posted candidates.
    ///
    /// This is cheaper than a full heartbeat — it performs a single Durable Object
    /// storage read with no writes, keeping Worker CPU usage minimal.
    ///
    /// - Parameter sessionID: Session identifier to check.
    /// - Returns: Client candidates if any have been posted.
    public func checkForClient(sessionID: String) async throws -> [LoomRemoteCandidate] {
        let (_, data) = try await sendSignedRequest(
            sessionID: sessionID,
            method: "GET",
            path: "/v1/session/check-client",
            bodyData: nil
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoomRemoteSignalingError.invalidPayload
        }
        return parseCandidates(object["clientCandidates"])
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
    public func fetchPresence(sessionID: String) async throws -> LoomRemotePresenceStatus {
        let (_, data) = try await sendSignedRequest(
            sessionID: sessionID,
            method: "GET",
            path: "/v1/session/presence",
            bodyData: nil
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoomRemoteSignalingError.invalidPayload
        }
        let exists = object["exists"] as? Bool ?? false
        let peerCandidates = parseCandidates(object["peerCandidates"] ?? object["hostCandidates"])
        let clientCandidates = parseCandidates(object["clientCandidates"])
        let acceptingConnections = object["remoteEnabled"] as? Bool ??
            object["acceptingConnections"] as? Bool ??
            false
        return LoomRemotePresenceStatus(
            exists: exists,
            acceptingConnections: acceptingConnections && !peerCandidates.isEmpty,
            advertisement: parseAdvertisementBlob(object["advertisementBlob"]),
            peerCandidates: peerCandidates,
            clientCandidates: clientCandidates,
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
        peerCandidates: [LoomRemoteCandidate],
        advertisement: LoomPeerAdvertisement?,
        ttlSeconds: Int
    )
    async throws {
        var body: [String: Any] = [
            "hostID": peerID.uuidString.lowercased(),
            "ttlSeconds": ttlSeconds,
            "remoteEnabled": acceptingConnections,
            "hostCandidates": encodeCandidates(peerCandidates),
        ]
        if let advertisementBlob = encodeAdvertisementBlob(advertisement) {
            body["advertisementBlob"] = advertisementBlob
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/create",
            bodyData: bodyData
        )
    }

    /// Creates a WebSocket connection to the signaling server for real-time
    /// session notifications (e.g., instant client-joined events).
    ///
    /// The upgrade request is signed with the current identity at call time.
    ///
    /// - Parameters:
    ///   - sessionID: The signaling session ID.
    ///   - role: "host" or "client".
    /// - Returns: A configured `LoomRemoteSignalingWebSocket` ready to connect,
    ///   or `nil` if signing fails.
    public func makeWebSocket(
        sessionID: String,
        role: String
    ) -> LoomRemoteSignalingWebSocket? {
        guard let identity = try? identityManager.currentIdentity() else { return nil }

        let path = "/v1/session/ws"
        let nonce = UUID().uuidString.lowercased()
        let timestampMs = LoomIdentitySigning.currentTimestampMs()
        let bodyHash = Self.sha256Hex(Data("-".utf8))
        let headerPrefix = configuration.headerPrefix
        let appAuth = configuration.appAuthentication

        let appPayload = Self.appAuthPayload(
            method: "GET", path: path, bodySHA256: bodyHash,
            appID: appAuth.appID, timestampMs: timestampMs, nonce: nonce,
            sessionID: sessionID
        )
        let appSig = Self.hmacSHA256Base64(payload: appPayload, secret: appAuth.sharedSecret)

        guard let workerPayload = try? LoomIdentitySigning.workerRequestPayload(
            method: "GET", path: path, bodySHA256: bodyHash,
            keyID: identity.keyID, timestampMs: timestampMs, nonce: nonce,
            sessionID: sessionID
        ),
              let sig = try? identityManager.sign(workerPayload) else { return nil }

        let headers: [(String, String)] = [
            ("\(headerPrefix)-session-id", sessionID),
            ("\(headerPrefix)-app-id", appAuth.appID),
            ("\(headerPrefix)-app-timestamp-ms", "\(timestampMs)"),
            ("\(headerPrefix)-app-nonce", nonce),
            ("\(headerPrefix)-app-signature", appSig),
            ("\(headerPrefix)-key-id", identity.keyID),
            ("\(headerPrefix)-public-key", identity.publicKey.base64EncodedString()),
            ("\(headerPrefix)-timestamp-ms", "\(timestampMs)"),
            ("\(headerPrefix)-nonce", nonce),
            ("\(headerPrefix)-signature", sig.base64EncodedString()),
            ("\(headerPrefix)-body-sha256", bodyHash),
        ]

        return LoomRemoteSignalingWebSocket(
            baseURL: configuration.baseURL,
            sessionID: sessionID,
            role: role,
            preSignedHeaders: headers
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
            throw LoomRemoteSignalingError.invalidConfiguration
        }
        let identity = try identityManager.currentIdentity()
        let nonce = UUID().uuidString.lowercased()
        let timestampMs = LoomIdentitySigning.currentTimestampMs()
        let bodyHash = Self.sha256Hex(bodyData ?? Data("-".utf8))
        let appAuthentication = configuration.appAuthentication
        LoomLogger.remoteSignaling(
            "Remote signaling request \(method.uppercased()) \(path) session=\(sessionID) keyID=\(identity.keyID) bodyBytes=\(bodyData?.count ?? 0)"
        )
        let appAuthPayload = Self.appAuthPayload(
            method: method,
            path: path,
            bodySHA256: bodyHash,
            appID: appAuthentication.appID,
            timestampMs: timestampMs,
            nonce: nonce,
            sessionID: sessionID
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
            nonce: nonce,
            sessionID: sessionID
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
            LoomLogger.error(.remoteSignaling, "Remote signaling invalid response for \(method.uppercased()) \(path)")
            throw LoomRemoteSignalingError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            let parsed = parseErrorPayload(data)
            LoomLogger.debug(.remoteSignaling,
                "Remote signaling HTTP \(http.statusCode) \(method.uppercased()) \(path) error=\(parsed.errorCode ?? "none") detail=\(parsed.detail ?? "none")"
            )
            throw LoomRemoteSignalingError.http(
                statusCode: http.statusCode,
                errorCode: parsed.errorCode,
                detail: parsed.detail
            )
        }
        LoomLogger.remoteSignaling(
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
        nonce: String,
        sessionID: String? = nil
    ) -> Data {
        var fields = [
            ("type", "worker-app-auth-v1"),
            ("method", method.uppercased()),
            ("path", path),
            ("bodySHA256", bodySHA256),
            ("appID", appID),
            ("timestampMs", "\(timestampMs)"),
            ("nonce", nonce),
        ]
        if let sessionID {
            fields[0] = ("type", "worker-app-auth-v2")
            fields.append(("sessionID", sessionID))
        }
        let text = fields
            .sorted { lhs, rhs in
                lhs.0 < rhs.0
            }
            .map { key, value in
                "\(key)=\(value)"
            }
            .joined(separator: "\n")
        return Data(text.utf8)
    }

    private static func hmacSHA256Base64(payload: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(signature).base64EncodedString()
    }

    private func encodeCandidates(_ candidates: [LoomRemoteCandidate]) -> [[String: Any]] {
        candidates.map { candidate in
            [
                "transport": candidate.transport.rawValue,
                "address": candidate.address,
                "port": Int(candidate.port),
            ]
        }
    }

    private func encodeAdvertisementBlob(_ advertisement: LoomPeerAdvertisement?) -> String? {
        guard let advertisement,
              let data = try? JSONEncoder().encode(advertisement) else {
            return nil
        }
        return data.base64EncodedString()
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

private func parseCandidates(_ rawValue: Any?) -> [LoomRemoteCandidate] {
    guard let array = rawValue as? [[String: Any]] else {
        return []
    }
    return array.compactMap { candidateObject in
        guard let transportRaw = candidateObject["transport"] as? String,
              let transport = LoomTransportKind(rawValue: transportRaw),
              let address = candidateObject["address"] as? String else {
            return nil
        }

        if let intPort = candidateObject["port"] as? Int,
           let port = UInt16(exactly: intPort) {
            return LoomRemoteCandidate(
                transport: transport,
                address: address,
                port: port
            )
        }

        if let int64Port = candidateObject["port"] as? Int64,
           let port = UInt16(exactly: int64Port) {
            return LoomRemoteCandidate(
                transport: transport,
                address: address,
                port: port
            )
        }

        return nil
    }
}

private func parseAdvertisementBlob(_ rawValue: Any?) -> LoomPeerAdvertisement? {
    guard let encoded = rawValue as? String,
          let data = Data(base64Encoded: encoded) else {
        return nil
    }
    return try? JSONDecoder().decode(LoomPeerAdvertisement.self, from: data)
}

#endif
