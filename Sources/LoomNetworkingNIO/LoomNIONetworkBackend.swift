//
//  LoomNIONetworkBackend.swift
//  LoomNetworkingNIO
//
//  Created by Ethan Lipnik on 7/10/26.
//

import LoomNetworking
import NIOCore
import NIOPosix

/// A SwiftNIO direct-socket backend for Loom stream and datagram transports.
///
/// The backend uses SwiftNIO's cross-platform socket implementation and does
/// not depend on Network.framework. DNS-SD discovery and platform services are
/// intentionally separate from this direct transport boundary.
public final class LoomNIONetworkBackend: LoomNetworkBackend, @unchecked Sendable {
    private let eventLoopGroup: any EventLoopGroup

    /// Creates a backend backed by SwiftNIO's process-wide event-loop group.
    public init() {
        eventLoopGroup = MultiThreadedEventLoopGroup.singleton
    }

    init(eventLoopGroup: any EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
    }

    public func makeConnection(
        to endpoint: LoomNetworkEndpoint,
        using transportKind: LoomTransportKind,
        configuration: LoomNetworkConnectionConfiguration
    ) throws -> any LoomNetworkConnection {
        guard configuration.requiredInterface == nil,
              configuration.requiredInterfaceType == nil else {
            throw LoomNetworkError(
                code: .unsupported,
                detail: "The SwiftNIO backend cannot bind by interface identity without a local address."
            )
        }
        guard endpoint.hostPort != nil else {
            throw LoomNetworkError(
                code: .unsupported,
                detail: "The SwiftNIO direct backend requires a resolved host/port endpoint."
            )
        }

        switch transportKind {
        case .tcp, .udp:
            return LoomNIOChannelConnection(
                transportKind: transportKind,
                remoteEndpoint: endpoint,
                eventLoopGroup: eventLoopGroup,
                requiredLocalPort: configuration.requiredLocalPort
            )
        case .quic:
            throw LoomNetworkError(
                code: .unsupported,
                detail: "QUIC transport is not implemented by Loom's SwiftNIO backend."
            )
        }
    }

    public func makeListener(
        using transportKind: LoomTransportKind,
        configuration: LoomNetworkListenerConfiguration
    ) throws -> any LoomNetworkListener {
        switch transportKind {
        case .tcp:
            return LoomNIOStreamListener(eventLoopGroup: eventLoopGroup)
        case .udp:
            return LoomNIODatagramListener(eventLoopGroup: eventLoopGroup)
        case .quic:
            throw LoomNetworkError(
                code: .unsupported,
                detail: "QUIC transport is not implemented by Loom's SwiftNIO backend."
            )
        }
    }
}

enum LoomNIOUtilities {
    static func socketAddress(for endpoint: LoomNetworkEndpoint) throws -> SocketAddress {
        guard case let .hostPort(host, port) = endpoint else {
            throw LoomNetworkError(
                code: .invalidConfiguration,
                detail: "A resolved host/port endpoint is required."
            )
        }
        do {
            return try SocketAddress.makeAddressResolvingHost(host.rawValue, port: Int(port))
        } catch {
            throw networkError(error)
        }
    }

    static func endpoint(for address: SocketAddress?) -> LoomNetworkEndpoint? {
        guard let address,
              var host = address.ipAddress,
              let port = address.port,
              let port = UInt16(exactly: port) else {
            return nil
        }
        if case let .v6(ipv6Address) = address {
            let scopeID = ipv6Address.address.sin6_scope_id
            if scopeID != 0 {
                host += "%\(scopeID)"
            }
        }
        return .hostPort(host: LoomNetworkHost(host), port: port)
    }

    static func wildcardAddress(matching remoteAddress: SocketAddress, port: UInt16) throws -> SocketAddress {
        let host = remoteAddress.protocol == .inet6 ? "::" : "0.0.0.0"
        do {
            return try SocketAddress(ipAddress: host, port: Int(port))
        } catch {
            throw networkError(error)
        }
    }

    static func path(
        localEndpoint: LoomNetworkEndpoint?,
        remoteEndpoint: LoomNetworkEndpoint
    ) -> LoomNetworkPath {
        let host = remoteEndpoint.hostPort?.host.rawValue.lowercased() ?? ""
        let unscopedHost = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        let isIPv4Mapped = unscopedHost.hasPrefix("::ffff:")
        let isIPv6 = unscopedHost.contains(":") && !isIPv4Mapped
        let isLoopback = unscopedHost == "::1" ||
            unscopedHost.hasPrefix("127.") ||
            unscopedHost.hasPrefix("::ffff:127.")
        return LoomNetworkPath(
            status: .satisfied,
            interfaces: [],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: !isIPv6,
            supportsIPv6: isIPv6,
            usesWiFi: false,
            usesWiredEthernet: false,
            usesCellular: false,
            usesLoopback: isLoopback,
            usesOther: !isLoopback,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint
        )
    }

    static func networkError(_ error: any Error) -> LoomNetworkError {
        if let error = error as? LoomNetworkError {
            return error
        }
        if error is CancellationError {
            return LoomNetworkError(code: .cancelled, detail: "Network operation cancelled.")
        }

        if let channelError = error as? ChannelError {
            let code: LoomNetworkErrorCode
            switch channelError {
            case .connectTimeout:
                code = .timedOut
            case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .eof:
                code = .closed
            case .operationUnsupported:
                code = .unsupported
            case .writeHostUnreachable:
                code = .unreachable
            default:
                code = .other
            }
            return LoomNetworkError(code: code, detail: channelError.description)
        }

        let detail = String(describing: error)
        let normalized = detail.lowercased()
        let code: LoomNetworkErrorCode
        if normalized.contains("refused") {
            code = .connectionRefused
        } else if normalized.contains("timed out") || normalized.contains("timeout") {
            code = .timedOut
        } else if normalized.contains("network is down") || normalized.contains("enetdown") {
            code = .networkDown
        } else if normalized.contains("unreachable") {
            code = .unreachable
        } else if normalized.contains("closed") || normalized.contains("reset") {
            code = .closed
        } else {
            code = .other
        }
        return LoomNetworkError(code: code, detail: detail)
    }
}
