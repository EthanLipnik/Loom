//
//  LoomEndpointResolver.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/22/26.
//

import Foundation
import Network

/// Pre-resolves `.local` mDNS hostnames to IP addresses before they reach
/// `NWConnection`.  UDP connections to unresolved `.local` names can stall in
/// `.waiting(ENETDOWN)` indefinitely; resolving first via `getaddrinfo` avoids
/// the issue because `getaddrinfo` blocks until `mDNSResponder` responds.
package enum LoomEndpointResolver {

    // MARK: - Cache

    // NSCache is internally thread-safe; the nonisolated(unsafe) marker
    // satisfies strict concurrency without adding unnecessary isolation.
    nonisolated(unsafe) private static let cache = NSCache<NSString, HostCacheEntry>()
    private static let cacheTTL: TimeInterval = 300 // 5 minutes

    /// Resolves a `.local` hostname to an IP-based `NWEndpoint`.
    ///
    /// Non-local hostnames and raw IP addresses pass through unchanged.
    /// Resolution is raced against `timeout` to avoid blocking forever.
    /// If pre-resolution fails, the unresolved `.local` hostname is returned
    /// so Network.framework can still attempt service discovery itself.
    /// Results are cached in memory with a 5-minute TTL; set the
    /// `LOOM_SKIP_ENDPOINT_CACHE` environment variable to bypass.
    package static func resolveHostPort(
        host: String,
        port: UInt16,
        timeout: Duration = .seconds(5),
        resolver: @Sendable (String, Duration) async throws -> NWEndpoint.Host = resolveWithTimeout
    ) async throws -> NWEndpoint {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LoomError.protocolError("Invalid port \(port)")
        }

        let lowered = host.lowercased()
        guard lowered.hasSuffix(".local") || lowered.hasSuffix(".local.") else {
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }

        let skipCache = ProcessInfo.processInfo.environment["LOOM_SKIP_ENDPOINT_CACHE"] != nil

        // Check cache first.
        if !skipCache,
           let entry = cache.object(forKey: host as NSString),
           CFAbsoluteTimeGetCurrent() - entry.timestamp < cacheTTL {
            LoomLogger.transport("Resolved \(host) → \(entry.host) (cached)")
            return .hostPort(host: entry.host, port: nwPort)
        }

        let resolved: NWEndpoint.Host
        do {
            resolved = try await resolver(host, timeout)
        } catch {
            if error is CancellationError {
                throw error
            }
            LoomLogger.transport(
                "Failed to pre-resolve \(host): \(error.localizedDescription); " +
                    "falling back to Network.framework resolution"
            )
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }

        if !skipCache {
            cache.setObject(
                HostCacheEntry(host: resolved),
                forKey: host as NSString
            )
        }

        return .hostPort(host: resolved, port: nwPort)
    }

    /// Removes all cached hostname resolutions.
    package static func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Private

    private static func resolveWithTimeout(
        host: String,
        timeout: Duration
    ) async throws -> NWEndpoint.Host {
        try await withThrowingTaskGroup(of: NWEndpoint.Host.self) { group in
            group.addTask {
                // getaddrinfo is a blocking syscall — run it on a
                // non-cooperative thread so we don't starve the pool.
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let resolved = try Self.resolveViaGetaddrinfo(host)
                            continuation.resume(returning: resolved)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LoomError.protocolError(
                    "Timed out resolving \(host) after \(timeout)"
                )
            }

            guard let result = try await group.next() else {
                throw LoomError.protocolError("Endpoint resolution produced no result")
            }
            group.cancelAll()
            return result
        }
    }

    private static func resolveViaGetaddrinfo(_ hostname: String) throws -> NWEndpoint.Host {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM

        var infoList: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &infoList)
        defer { if let list = infoList { freeaddrinfo(list) } }

        guard status == 0, let first = infoList else {
            let message = String(cString: gai_strerror(status))
            throw LoomError.protocolError(
                "Failed to resolve \(hostname): \(message)"
            )
        }

        // Walk the linked list, preferring IPv4 for LAN mDNS.
        var ipv6Fallback: NWEndpoint.Host?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            switch entry.pointee.ai_family {
            case AF_INET:
                var addr = entry.pointee.ai_addr.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) { $0.pointee }
                let ipv4Data = Data(bytes: &addr.sin_addr, count: MemoryLayout<in_addr>.size)
                if let ipv4 = IPv4Address(ipv4Data) {
                    LoomLogger.transport("Resolved \(hostname) → \(ipv4)")
                    return .ipv4(ipv4)
                }
            case AF_INET6:
                if ipv6Fallback == nil {
                    var addr = entry.pointee.ai_addr.withMemoryRebound(
                        to: sockaddr_in6.self,
                        capacity: 1
                    ) { $0.pointee }
                    let data = Data(bytes: &addr.sin6_addr, count: MemoryLayout<in6_addr>.size)
                    if let ipv6 = IPv6Address(data) {
                        ipv6Fallback = .ipv6(ipv6)
                    }
                }
            default:
                break
            }
            cursor = entry.pointee.ai_next
        }

        if let fallback = ipv6Fallback {
            LoomLogger.transport("Resolved \(hostname) → \(fallback) (IPv6)")
            return fallback
        }

        throw LoomError.protocolError(
            "No usable address found for \(hostname)"
        )
    }
}

// MARK: - Cache Entry

private final class HostCacheEntry: @unchecked Sendable {
    let host: NWEndpoint.Host
    let timestamp: CFAbsoluteTime

    init(host: NWEndpoint.Host) {
        self.host = host
        self.timestamp = CFAbsoluteTimeGetCurrent()
    }
}
