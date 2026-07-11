//
//  LoomKeychainIdentityKeyStorage.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

#if canImport(Security)
import Foundation
import LoomNetworking
import Security

final class LoomKeychainIdentityKeyStorage: LoomIdentityKeyStorage, @unchecked Sendable {
    private let service: String
    private let account: String
    private let synchronizable: Bool
    private let fallbackToNonSynchronizableStorage: Bool

    init(
        service: String,
        account: String,
        synchronizable: Bool,
        fallbackToNonSynchronizableStorage: Bool
    ) {
        self.service = service
        self.account = account
        self.synchronizable = synchronizable
        self.fallbackToNonSynchronizableStorage = fallbackToNonSynchronizableStorage
    }

    func loadPrivateKey() throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw LoomIdentityError.keychainReadFailed(status: status)
        }
        guard let data = item as? Data else {
            throw LoomIdentityError.invalidKeyData
        }
        return data
    }

    func storePrivateKey(_ privateKey: Data) throws {
        do {
            try storePrivateKey(privateKey, synchronizable: synchronizable)
        } catch {
            guard LoomIdentityManager.shouldFallbackToNonSynchronizableStorage(
                synchronizable: synchronizable,
                fallbackEnabled: fallbackToNonSynchronizableStorage,
                error: error
            ) else {
                throw error
            }

            let status = LoomIdentityManager.keychainWriteStatus(from: error) ?? 0
            LoomLogger.identity(
                "Synchronizable identity key write failed status=\(status); using local Keychain storage"
            )
            try storePrivateKey(privateKey, synchronizable: false)
        }
    }

    func deletePrivateKey() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LoomIdentityError.keychainDeleteFailed(status: status)
        }
    }

    private func storePrivateKey(_ privateKey: Data, synchronizable: Bool) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        attributes[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
            let update: [String: Any] = [
                kSecValueData as String: privateKey,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw LoomIdentityError.keychainWriteFailed(status: updateStatus)
            }
            return
        }
        throw LoomIdentityError.keychainWriteFailed(status: status)
    }
}
#endif
