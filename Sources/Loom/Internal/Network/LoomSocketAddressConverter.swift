//
//  LoomSocketAddressConverter.swift
//  Loom
//
//  Created by OpenAI on 5/19/26.
//

#if canImport(Network)
import Foundation
import Network

package enum LoomSocketAddressConverter {
    package static func host(fromIPv4 address: sockaddr_in) -> NWEndpoint.Host? {
        var ipv4Address = address.sin_addr
        let data = Data(bytes: &ipv4Address, count: MemoryLayout<in_addr>.size)
        guard let ipv4 = IPv4Address(data) else { return nil }
        return .ipv4(ipv4)
    }

    package static func host(fromIPv6 address: sockaddr_in6) -> NWEndpoint.Host? {
        guard let ipv6 = ipv6Address(from: address) else { return nil }
        return .ipv6(ipv6)
    }

    package static func ipv6Address(from address: sockaddr_in6) -> IPv6Address? {
        var ipv6Address = address.sin6_addr
        let data = Data(bytes: &ipv6Address, count: MemoryLayout<in6_addr>.size)
        guard let unscopedAddress = IPv6Address(data) else { return nil }
        guard address.sin6_scope_id != 0 else { return unscopedAddress }
        guard let interfaceName = interfaceName(for: address.sin6_scope_id) else {
            return isLinkLocalIPv6Address(unscopedAddress) ? nil : unscopedAddress
        }
        if let scopedAddress = IPv6Address("\(unscopedAddress)%\(interfaceName)") {
            return scopedAddress
        }
        return isLinkLocalIPv6Address(unscopedAddress) ? nil : unscopedAddress
    }

    private static func interfaceName(for index: UInt32) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return nameBuffer.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let baseAddress = buffer.baseAddress,
                  if_indextoname(index, baseAddress) != nil else {
                return nil
            }
            return String(cString: baseAddress)
        }
    }

    private static func isLinkLocalIPv6Address(_ address: IPv6Address) -> Bool {
        let raw = address.rawValue
        guard raw.count >= 2 else { return false }
        return raw[raw.startIndex] == 0xFE &&
            (raw[raw.index(after: raw.startIndex)] & 0xC0) == 0x80
    }
}

#endif
