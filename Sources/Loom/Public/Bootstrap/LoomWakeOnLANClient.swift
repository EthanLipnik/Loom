//
//  LoomWakeOnLANClient.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Wake-on-LAN runtime for peer bootstrap.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif
import NIOCore
import NIOPosix

/// Wake-on-LAN failures.
public enum LoomWakeOnLANError: LocalizedError, Sendable {
    case invalidMACAddress
    case noBroadcastTargets
    case sendFailed(String)

    /// Human-readable error text for diagnostics and UI.
    public var errorDescription: String? {
        switch self {
        case .invalidMACAddress:
            "Wake-on-LAN failed: MAC address is invalid."
        case .noBroadcastTargets:
            "Wake-on-LAN failed: no broadcast targets are available."
        case let .sendFailed(detail):
            "Wake-on-LAN failed: \(detail)"
        }
    }
}

/// Sends Wake-on-LAN magic packets to configured broadcast targets.
public protocol LoomWakeOnLANClient: Sendable {
    /// Sends one or more magic packets to wake a peer device.
    ///
    /// - Parameters:
    ///   - wakeInfo: Target MAC and broadcast address metadata.
    ///   - retries: Additional retry attempts after the initial send.
    ///   - retryDelay: Delay between retry attempts.
    /// - Throws: ``LoomWakeOnLANError`` when packet construction or sending fails.
    func sendMagicPacket(
        _ wakeInfo: LoomWakeOnLANInfo,
        retries: Int,
        retryDelay: Duration
    ) async throws
}

/// Default Wake-on-LAN sender used by bootstrap coordinators.
public final class LoomDefaultWakeOnLANClient: LoomWakeOnLANClient {
    private static let wakeOnLANPort: UInt16 = 9

    /// Creates the default UDP-based Wake-on-LAN sender.
    public init() {}

    /// Sends Wake-on-LAN magic packets to all configured broadcast targets.
    ///
    /// - Parameters:
    ///   - wakeInfo: Contains the target MAC address and broadcast destinations.
    ///   - retries: Number of retries after the first attempt.
    ///   - retryDelay: Delay used between attempts.
    ///
    /// Example:
    /// ```swift
    /// let client = LoomDefaultWakeOnLANClient()
    /// try await client.sendMagicPacket(
    ///     .init(macAddress: "AA:BB:CC:DD:EE:FF", broadcastAddresses: ["192.168.1.255"])
    /// )
    /// ```
    public func sendMagicPacket(
        _ wakeInfo: LoomWakeOnLANInfo,
        retries: Int = 2,
        retryDelay: Duration = .milliseconds(400)
    )
    async throws {
        let packet = try Self.magicPacketData(for: wakeInfo.macAddress)
        let targets = wakeInfo.broadcastAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targets.isEmpty else { throw LoomWakeOnLANError.noBroadcastTargets }

        let attempts = max(1, retries + 1)
        var lastError: Error?

        for attempt in 1 ... attempts {
            do {
                try await send(packet: packet, to: targets)
                return
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(for: retryDelay)
                }
            }
        }

        if let wakeOnLANError = lastError as? LoomWakeOnLANError {
            throw wakeOnLANError
        }

        let detail = lastError.map(Self.sendFailureDetail) ?? "unknown send error"
        throw LoomWakeOnLANError.sendFailed(detail)
    }

    private func send(packet: Data, to targets: [String]) async throws {
        let addresses = try targets.map { target -> SocketAddress in
            guard Self.isIPv4Address(target) else {
                throw LoomWakeOnLANError.sendFailed("invalid IPv4 broadcast target \(target)")
            }
            do {
                return try SocketAddress(ipAddress: target, port: Int(Self.wakeOnLANPort))
            } catch {
                throw LoomWakeOnLANError.sendFailed("invalid IPv4 broadcast target \(target)")
            }
        }
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.socketOption(.so_broadcast), value: 1)
            .bind(host: "0.0.0.0", port: 0)
            .get()
        do {
            for address in addresses {
                var buffer = channel.allocator.buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                try await channel.writeAndFlush(
                    AddressedEnvelope(remoteAddress: address, data: buffer)
                ).get()
            }
            try await channel.close().get()
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

#if canImport(Darwin)
    static func ipv4Address(for target: String) throws -> in_addr {
        var address = in_addr()
        let result = target.withCString { inet_pton(AF_INET, $0, &address) }
        if result == 1 {
            return address
        }
        if result == 0 {
            throw LoomWakeOnLANError.sendFailed("invalid IPv4 broadcast target \(target)")
        }
        throw POSIXError(Self.currentPOSIXErrorCode())
    }
#endif

    private static func isIPv4Address(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && UInt8(component) != nil
        }
    }

    static func sendFailureDetail(for error: Error) -> String {
        if let code = posixCode(from: error) {
            switch code {
            case .EACCES:
                return "permission denied sending UDP broadcast; allow Local Network access and make sure the app is signed with the multicast networking entitlement on iOS, iPadOS, and visionOS"
            default:
                return "\(code): \(String(cString: strerror(code.rawValue)))"
            }
        }

        return String(describing: error)
    }

    private static func posixCode(from error: Error) -> POSIXErrorCode? {
        if let posixError = error as? POSIXError {
            return posixError.code
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return POSIXErrorCode(rawValue: Int32(nsError.code))
        }

        return nil
    }

#if canImport(Darwin)
    private static func currentPOSIXErrorCode() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }
#endif

    /// Builds a standard Wake-on-LAN magic packet for a MAC address.
    ///
    /// - Parameter macAddress: MAC value in `AA:BB:CC:DD:EE:FF`, `AA-BB-...`, or compact hex format.
    /// - Returns: Packet payload containing `FF` preamble plus 16 MAC repetitions.
    /// - Throws: ``LoomWakeOnLANError/invalidMACAddress`` when the address cannot be parsed.
    public static func magicPacketData(for macAddress: String) throws -> Data {
        let separators = CharacterSet(charactersIn: ":-.")
        let compact = macAddress.unicodeScalars.filter { !separators.contains($0) }
        let normalized = String(String.UnicodeScalarView(compact))

        guard normalized.count == 12 else { throw LoomWakeOnLANError.invalidMACAddress }
        var macBytes: [UInt8] = []
        macBytes.reserveCapacity(6)

        var index = normalized.startIndex
        for _ in 0 ..< 6 {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteText = normalized[index ..< nextIndex]
            guard let byte = UInt8(byteText, radix: 16) else {
                throw LoomWakeOnLANError.invalidMACAddress
            }
            macBytes.append(byte)
            index = nextIndex
        }

        var payload = Data(repeating: 0xFF, count: 6)
        for _ in 0 ..< 16 {
            payload.append(contentsOf: macBytes)
        }
        return payload
    }
}
