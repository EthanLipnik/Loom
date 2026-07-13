//
//  LoomPlatformProtectedIdentityKeyStorage.swift
//  LoomPlatformAdapters
//
//  Created by Ethan Lipnik on 7/10/26.
//

#if os(Windows)
import CLoomPlatformSupport
import Foundation
import LoomNetworking

/// Current-user protected identity storage used by the platform default adapter.
public final class LoomPlatformProtectedIdentityKeyStorage: LoomIdentityKeyStorage, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(service: String, account: String) {
        let environment = ProcessInfo.processInfo.environment
        let baseURL: URL
        if let localAppData = environment["LOCALAPPDATA"], !localAppData.isEmpty {
            baseURL = URL(fileURLWithPath: localAppData, isDirectory: true)
        } else {
            baseURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("AppData", isDirectory: true)
                .appendingPathComponent("Local", isDirectory: true)
        }
        let identifier = Self.stableIdentifier("\(service)\u{0}\(account)")
        fileURL = baseURL
            .appendingPathComponent("Loom", isDirectory: true)
            .appendingPathComponent("Identity", isDirectory: true)
            .appendingPathComponent("identity-\(identifier).loomidentity", isDirectory: false)
    }

    public func loadPrivateKey() throws -> Data? {
        try lock.withLock {
            var output: UnsafeMutablePointer<UInt8>?
            var outputLength = 0
            var exists: Int32 = 0
            var errorCode: UInt32 = 0
            let succeeded = fileURL.path.withCString { path in
                loom_platform_read_file(
                    path,
                    LoomProtectedIdentityFile.maximumProtectedBytes + 16,
                    &output,
                    &outputLength,
                    &exists,
                    &errorCode
                )
            }
            guard succeeded != 0 else {
                throw LoomIdentityKeyStorageError.unreadable(
                    code: errorCode,
                    detail: "Protected identity file could not be read."
                )
            }
            guard exists != 0 else { return nil }
            guard let output else {
                throw LoomIdentityKeyStorageError.corrupted(detail: "Protected identity file is empty.")
            }
            let fileData = Data(bytes: output, count: outputLength)
            loom_platform_free(output)
            let protectedBytes = try LoomProtectedIdentityFile.decode(fileData)
            return try unprotect(protectedBytes)
        }
    }

    public func storePrivateKey(_ privateKey: Data) throws {
        try lock.withLock {
            guard !privateKey.isEmpty else {
                throw LoomIdentityKeyStorageError.corrupted(detail: "Refusing to store an empty identity key.")
            }
            let protectedBytes = try protect(privateKey)
            let fileData = try LoomProtectedIdentityFile.encode(protectedBytes: protectedBytes)
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw LoomIdentityKeyStorageError.persistenceFailed(
                    code: 0,
                    detail: "Identity directory creation failed: \(error.localizedDescription)"
                )
            }

            var errorCode: UInt32 = 0
            let succeeded = fileURL.path.withCString { path in
                fileData.withUnsafeBytes { bytes in
                    loom_platform_atomic_replace_user_only(
                        path,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count,
                        &errorCode
                    )
                }
            }
            guard succeeded != 0 else {
                throw LoomIdentityKeyStorageError.permissionFailed(
                    code: errorCode,
                    detail: "Protected identity file could not be atomically replaced with a user-only ACL."
                )
            }
        }
    }

    public func deletePrivateKey() throws {
        try lock.withLock {
            var errorCode: UInt32 = 0
            let succeeded = fileURL.path.withCString { path in
                loom_platform_delete_file(path, &errorCode)
            }
            guard succeeded != 0 else {
                throw LoomIdentityKeyStorageError.persistenceFailed(
                    code: errorCode,
                    detail: "Protected identity file could not be deleted."
                )
            }
        }
    }

    private func protect(_ privateKey: Data) throws -> Data {
        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        var errorCode: UInt32 = 0
        let succeeded = privateKey.withUnsafeBytes { bytes in
            loom_platform_protect_current_user(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &output,
                &outputLength,
                &errorCode
            )
        }
        guard succeeded != 0, let output else {
            throw LoomIdentityKeyStorageError.protectionFailed(
                code: errorCode,
                detail: "Current-user data protection failed."
            )
        }
        let protectedBytes = Data(bytes: output, count: outputLength)
        loom_platform_free(output)
        return protectedBytes
    }

    private func unprotect(_ protectedBytes: Data) throws -> Data {
        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        var errorCode: UInt32 = 0
        let succeeded = protectedBytes.withUnsafeBytes { bytes in
            loom_platform_unprotect_current_user(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &output,
                &outputLength,
                &errorCode
            )
        }
        guard succeeded != 0, let output else {
            throw LoomIdentityKeyStorageError.unreadable(
                code: errorCode,
                detail: "The protected identity cannot be decrypted for the current user."
            )
        }
        let privateKey = Data(bytes: output, count: outputLength)
        loom_platform_secure_free(output, outputLength)
        return privateKey
    }

    private static func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
#endif
