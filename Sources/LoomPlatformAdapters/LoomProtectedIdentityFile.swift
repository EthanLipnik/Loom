//
//  LoomProtectedIdentityFile.swift
//  LoomPlatformAdapters
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking

/// Versioned envelope around a platform-protected identity blob.
public enum LoomProtectedIdentityFile {
    public static let currentVersion: UInt16 = 1
    public static let maximumProtectedBytes = 1_048_576

    private static let magic = Data([0x4c, 0x4f, 0x4f, 0x4d, 0x49, 0x44, 0x00, 0x00])
    private static let currentUserProtectionFlag: UInt16 = 1
    private static let headerByteCount = 16

    public static func encode(protectedBytes: Data) throws -> Data {
        guard protectedBytes.count <= maximumProtectedBytes,
              let length = UInt32(exactly: protectedBytes.count) else {
            throw LoomIdentityKeyStorageError.corrupted(detail: "Protected identity payload is too large.")
        }
        var data = Data(capacity: headerByteCount + protectedBytes.count)
        data.append(magic)
        append(currentVersion, to: &data)
        append(currentUserProtectionFlag, to: &data)
        append(length, to: &data)
        data.append(protectedBytes)
        return data
    }

    public static func decode(_ data: Data) throws -> Data {
        guard data.count >= headerByteCount else {
            throw LoomIdentityKeyStorageError.corrupted(detail: "Identity file header is truncated.")
        }
        guard data.prefix(magic.count) == magic else {
            throw LoomIdentityKeyStorageError.corrupted(detail: "Identity file magic is invalid.")
        }
        let version: UInt16 = read(from: data, offset: 8)
        guard version == currentVersion else {
            throw LoomIdentityKeyStorageError.unsupportedVersion(version)
        }
        let flags: UInt16 = read(from: data, offset: 10)
        guard flags == currentUserProtectionFlag else {
            throw LoomIdentityKeyStorageError.corrupted(detail: "Identity file protection flags are invalid.")
        }
        let protectedLength: UInt32 = read(from: data, offset: 12)
        guard protectedLength <= maximumProtectedBytes,
              data.count == headerByteCount + Int(protectedLength) else {
            throw LoomIdentityKeyStorageError.corrupted(detail: "Identity file payload length is invalid.")
        }
        return Data(data.dropFirst(headerByteCount))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndianValue = value.bigEndian
        withUnsafeBytes(of: &bigEndianValue) {
            data.append(contentsOf: $0)
        }
    }

    private static func read<T: FixedWidthInteger>(from data: Data, offset: Int) -> T {
        data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: T.self).bigEndian
        }
    }
}
