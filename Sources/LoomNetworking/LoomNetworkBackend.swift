//
//  LoomNetworkBackend.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Stable failure categories reported across Loom network backends.
public enum LoomNetworkErrorCode: String, Codable, Hashable, Sendable {
    case cancelled
    case closed
    case connectionRefused
    case invalidConfiguration
    case networkDown
    case timedOut
    case unreachable
    case unsupported
    case other
}

/// A sendable error value that does not expose platform socket error types.
public struct LoomNetworkError: Error, Codable, Hashable, Sendable {
    public let code: LoomNetworkErrorCode
    public let detail: String

    public init(code: LoomNetworkErrorCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

extension LoomNetworkError: CustomStringConvertible {
    public var description: String {
        detail
    }
}

extension LoomNetworkError: LocalizedError {
    public var errorDescription: String? {
        detail
    }
}

/// Path and lifecycle events emitted after a connection starts.
public enum LoomNetworkConnectionEvent: Sendable {
    case path(LoomNetworkPath)
    case failed(LoomNetworkError)
    case cancelled
}

/// Backend-neutral options for one outgoing direct connection.
public struct LoomNetworkConnectionConfiguration: Hashable, Sendable {
    public var enablePeerToPeer: Bool
    public var requiredInterface: LoomNetworkInterface?
    public var requiredInterfaceType: LoomNetworkInterfaceType?
    public var requiredLocalPort: UInt16?
    public var datagramServiceClass: LoomNetworkServiceClass

    public init(
        enablePeerToPeer: Bool = false,
        requiredInterface: LoomNetworkInterface? = nil,
        requiredInterfaceType: LoomNetworkInterfaceType? = nil,
        requiredLocalPort: UInt16? = nil,
        datagramServiceClass: LoomNetworkServiceClass = .interactiveVideo
    ) {
        self.enablePeerToPeer = enablePeerToPeer
        self.requiredInterface = requiredInterface
        self.requiredInterfaceType = requiredInterfaceType
        self.requiredLocalPort = requiredLocalPort
        self.datagramServiceClass = datagramServiceClass
    }
}

/// Backend-neutral options for one direct listener.
public struct LoomNetworkListenerConfiguration: Hashable, Sendable {
    public var enablePeerToPeer: Bool
    public var datagramServiceClass: LoomNetworkServiceClass

    public init(
        enablePeerToPeer: Bool = false,
        datagramServiceClass: LoomNetworkServiceClass = .interactiveVideo
    ) {
        self.enablePeerToPeer = enablePeerToPeer
        self.datagramServiceClass = datagramServiceClass
    }
}

/// A connected byte stream or message-preserving datagram flow.
///
/// Stream receives may return fewer bytes than requested. Datagram receives
/// preserve exactly one datagram. `nil` indicates an orderly peer close.
public protocol LoomNetworkConnection: Sendable {
    var transportKind: LoomTransportKind { get }
    var remoteEndpoint: LoomNetworkEndpoint { get }
    var localEndpoint: LoomNetworkEndpoint? { get async }
    /// Latest path snapshot retained by the backend after the connection starts.
    var currentPath: LoomNetworkPath? { get async }

    func start() async throws
    func send(_ data: Data) async throws
    func receive(maximumBytes: Int) async throws -> Data?
    func makeEventStream() async -> AsyncStream<LoomNetworkConnectionEvent>
    func cancel() async
}

public extension LoomNetworkConnection {
    /// Backends that do not expose path metadata remain source compatible and
    /// can rely on lifecycle events alone.
    var currentPath: LoomNetworkPath? {
        get async { nil }
    }
}

/// A listening socket that yields backend-neutral accepted connections.
public protocol LoomNetworkListener: Sendable {
    var transportKind: LoomTransportKind { get }

    func start(port: UInt16) async throws -> UInt16
    func makeConnectionStream() async -> AsyncStream<any LoomNetworkConnection>
    func cancel() async
}

/// Factory boundary for direct stream and datagram sockets.
public protocol LoomNetworkBackend: Sendable {
    func makeConnection(
        to endpoint: LoomNetworkEndpoint,
        using transportKind: LoomTransportKind,
        configuration: LoomNetworkConnectionConfiguration
    ) throws -> any LoomNetworkConnection

    func makeListener(
        using transportKind: LoomTransportKind,
        configuration: LoomNetworkListenerConfiguration
    ) throws -> any LoomNetworkListener
}
