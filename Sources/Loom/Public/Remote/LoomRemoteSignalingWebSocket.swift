//
//  LoomRemoteSignalingWebSocket.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//
//  WebSocket client for real-time signaling notifications.  The host
//  connects via WebSocket to receive instant "clientJoined" events
//  instead of polling.
//

import Foundation

/// Events delivered through the signaling WebSocket.
public enum LoomSignalingWebSocketEvent: Sendable {
    /// A client just joined the session with these candidates.
    case clientJoined(candidates: [LoomRemoteCandidate])
    /// The host published updated candidates.
    case candidatesUpdated(candidates: [LoomRemoteCandidate])
    /// The WebSocket disconnected.
    case disconnected
}

/// Maintains a WebSocket connection to the signaling server for instant
/// push notifications about session events.
public actor LoomRemoteSignalingWebSocket {
    private let baseURL: URL
    private let sessionID: String
    private let role: String
    private let preSignedHeaders: [(String, String)]
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<LoomSignalingWebSocketEvent>.Continuation?
    private var _isAlive = false

    /// Whether the WebSocket connection is alive and receiving events.
    public var isAlive: Bool { _isAlive }

    /// Stream of signaling events.  Subscribe to this to receive real-time
    /// notifications from the signaling server.
    public nonisolated let events: AsyncStream<LoomSignalingWebSocketEvent>

    /// Creates a signaling WebSocket.
    ///
    /// - Parameters:
    ///   - baseURL: The signaling server base URL (https).
    ///   - sessionID: The signaling session ID.
    ///   - role: "host" or "client".
    ///   - preSignedHeaders: Authentication headers pre-computed by the signaling client.
    public init(
        baseURL: URL,
        sessionID: String,
        role: String,
        preSignedHeaders: [(String, String)]
    ) {
        self.baseURL = baseURL
        self.sessionID = sessionID
        self.role = role
        self.preSignedHeaders = preSignedHeaders

        var continuation: AsyncStream<LoomSignalingWebSocketEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    /// Opens the WebSocket connection.
    public func connect() {
        disconnect()

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/session/ws"),
            resolvingAgainstBaseURL: false
        ) else { return }

        components.queryItems = [URLQueryItem(name: "role", value: role)]

        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }

        guard let wsURL = components.url else { return }

        var request = URLRequest(url: wsURL)
        for (name, value) in preSignedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTask = task
        _isAlive = true
        task.resume()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    /// Closes the WebSocket connection.
    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        _isAlive = false
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Private

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    handleMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    eventContinuation?.yield(.disconnected)
                }
                break
            }
        }
        _isAlive = false
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "clientJoined":
            if let rawCandidates = json["clientCandidates"] as? [[String: Any]] {
                let candidates = Self.parseCandidates(rawCandidates)
                eventContinuation?.yield(.clientJoined(candidates: candidates))
            }
        case "hostCandidatesUpdated":
            if let rawCandidates = json["hostCandidates"] as? [[String: Any]] {
                let candidates = Self.parseCandidates(rawCandidates)
                eventContinuation?.yield(.candidatesUpdated(candidates: candidates))
            }
        default:
            break
        }
    }

    private static func parseCandidates(_ raw: [[String: Any]]) -> [LoomRemoteCandidate] {
        raw.compactMap { dict in
            guard let transportStr = dict["transport"] as? String,
                  let transport = LoomTransportKind(rawValue: transportStr),
                  let address = dict["address"] as? String,
                  let rawPort = dict["port"] as? Int,
                  let port = UInt16(exactly: rawPort) else { return nil }
            return LoomRemoteCandidate(transport: transport, address: address, port: port)
        }
    }

    deinit {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
        eventContinuation?.finish()
    }
}
