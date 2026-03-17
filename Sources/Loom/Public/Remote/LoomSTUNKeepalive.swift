//
//  LoomSTUNKeepalive.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/16/26.
//
//  Periodic STUN binding refresh to keep NAT mappings alive for direct
//  inbound QUIC connections.
//

import Foundation
import Network

/// Periodically sends STUN binding requests from a fixed local port to keep
/// the NAT mapping alive so that remote clients can reach the host's QUIC
/// listener through the mapped public endpoint.
///
/// Usage:
/// ```swift
/// let keepalive = LoomSTUNKeepalive(localPort: quicListenerPort)
/// let initial = await keepalive.start()
/// // ... later ...
/// keepalive.stop()
/// ```
public final class LoomSTUNKeepalive: @unchecked Sendable {
    private let localPort: UInt16
    private let stunHost: String
    private let stunPort: UInt16
    private let interval: Duration

    private let lock = NSLock()
    private var keepaliveTask: Task<Void, Never>?
    private var _latestResult: LoomSTUNProbeResult?

    /// The most recently observed STUN mapping, or `nil` if the keepalive
    /// has not been started or was stopped.
    public var latestResult: LoomSTUNProbeResult? {
        lock.withLock { _latestResult }
    }

    /// Creates a STUN keepalive.
    ///
    /// - Parameters:
    ///   - localPort: The QUIC listener port to send probes from.
    ///   - stunHost: STUN server hostname.
    ///   - stunPort: STUN server UDP port.
    ///   - interval: Time between keepalive probes (default 25 s).
    public init(
        localPort: UInt16,
        stunHost: String = "stun.cloudflare.com",
        stunPort: UInt16 = 3478,
        interval: Duration = .seconds(25)
    ) {
        self.localPort = localPort
        self.stunHost = stunHost
        self.stunPort = stunPort
        self.interval = interval
    }

    /// Runs the initial STUN probe, starts the background refresh loop,
    /// and returns the first probe result.
    public func start() async -> LoomSTUNProbeResult {
        stop()

        let initial = await LoomSTUNProbe.run(
            host: stunHost,
            port: stunPort,
            localPort: localPort
        )
        lock.withLock { _latestResult = initial }

        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { break }

                let result = await LoomSTUNProbe.run(
                    host: self.stunHost,
                    port: self.stunPort,
                    localPort: self.localPort
                )

                let previousPort = self.lock.withLock { self._latestResult?.mappedPort }
                self.lock.withLock { self._latestResult = result }

                if result.reachable,
                   let newPort = result.mappedPort,
                   let previousPort,
                   newPort != previousPort {
                    LoomLogger.log(
                        .transport,
                        "STUN keepalive mapping drifted: \(previousPort) -> \(newPort)"
                    )
                }
            }
        }
        lock.withLock { keepaliveTask = task }
        return initial
    }

    /// Cancels the background refresh loop.
    public func stop() {
        lock.withLock {
            keepaliveTask?.cancel()
            keepaliveTask = nil
            _latestResult = nil
        }
    }

    deinit {
        keepaliveTask?.cancel()
    }
}
