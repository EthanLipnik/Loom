//
//  LoomSharedDeviceID.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Shared App Group-backed device identifier used by Loom-powered apps.
//

import Foundation

/// Provides a stable device identifier shared between cooperating Loom apps.
///
/// Uses App Groups to share a single UUID between multiple app targets so a
/// product can filter out its own device from discovered peers.
public enum LoomSharedDeviceID {
    /// UserDefaults key for the shared device ID.
    public static let key = "com.loom.shared.deviceID"
    /// Legacy keys preserved for migration from older Loom layouts.
    public static let legacyKeys = [
        "com.loom.client.deviceID",
        "com.loom.cloudkit.deviceID",
    ]

    /// Returns the shared device ID, creating one if needed.
    ///
    /// Priority:
    /// 1. Existing ID in shared App Group suite
    /// 2. Migration from old per-app keys
    /// 3. Create new ID
    public static func getOrCreate(
        suiteName: String? = nil,
        key: String = LoomSharedDeviceID.key,
        legacyKeys: [String] = LoomSharedDeviceID.legacyKeys
    ) -> UUID {
        let sharedDefaults = userDefaults(suiteName: suiteName)
        let resolvedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.key : key

        if let stored = sharedDefaults.string(forKey: resolvedKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }

        for oldKey in mergedLegacyKeys(legacyKeys) {
            if let old = sharedDefaults.string(forKey: oldKey),
               let uuid = UUID(uuidString: old) {
                sharedDefaults.set(uuid.uuidString, forKey: resolvedKey)
                return uuid
            }
            if let old = UserDefaults.standard.string(forKey: oldKey),
               let uuid = UUID(uuidString: old) {
                sharedDefaults.set(uuid.uuidString, forKey: resolvedKey)
                return uuid
            }
        }

        let newID = UUID()
        sharedDefaults.set(newID.uuidString, forKey: resolvedKey)
        return newID
    }

    private static func mergedLegacyKeys(_ additionalKeys: [String]) -> [String] {
        var resolved: [String] = []
        for candidate in additionalKeys + legacyKeys where !resolved.contains(candidate) {
            resolved.append(candidate)
        }
        return resolved
    }

    private static func userDefaults(suiteName: String?) -> UserDefaults {
        guard let suiteName = suiteName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suiteName.isEmpty,
              let sharedDefaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }

        return sharedDefaults
    }
}
