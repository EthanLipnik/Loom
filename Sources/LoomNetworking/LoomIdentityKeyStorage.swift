//
//  LoomIdentityKeyStorage.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Storage boundary for a raw private identity key.
public protocol LoomIdentityKeyStorage: Sendable {
    /// Returns `nil` only when no protected identity has ever been stored.
    func loadPrivateKey() throws -> Data?
    func storePrivateKey(_ privateKey: Data) throws
    func deletePrivateKey() throws
}

/// Portable identity-storage failures with explicit missing/corrupt distinctions.
public enum LoomIdentityKeyStorageError: Error, Equatable, LocalizedError, Sendable {
    case unreadable(code: UInt32, detail: String)
    case corrupted(detail: String)
    case unsupportedVersion(UInt16)
    case protectionFailed(code: UInt32, detail: String)
    case persistenceFailed(code: UInt32, detail: String)
    case permissionFailed(code: UInt32, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(code, detail):
            "Identity key storage is unreadable (\(code)): \(detail)"
        case let .corrupted(detail):
            "Identity key storage is corrupted: \(detail)"
        case let .unsupportedVersion(version):
            "Identity key storage version \(version) is unsupported."
        case let .protectionFailed(code, detail):
            "Identity key protection failed (\(code)): \(detail)"
        case let .persistenceFailed(code, detail):
            "Identity key persistence failed (\(code)): \(detail)"
        case let .permissionFailed(code, detail):
            "Identity key permissions could not be secured (\(code)): \(detail)"
        }
    }
}

/// Process-memory identity storage used by tests and explicitly ephemeral peers.
public final class LoomMemoryIdentityKeyStorage: LoomIdentityKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var privateKey: Data?

    public init(privateKey: Data? = nil) {
        self.privateKey = privateKey
    }

    public func loadPrivateKey() -> Data? {
        lock.withLock { privateKey }
    }

    public func storePrivateKey(_ privateKey: Data) {
        lock.withLock {
            self.privateKey = privateKey
        }
    }

    public func deletePrivateKey() {
        lock.withLock {
            privateKey = nil
        }
    }
}
