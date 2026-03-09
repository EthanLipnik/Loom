//
//  LoomTrustStore.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/21/26.
//

import Foundation
import Observation

/// Trusted device record used by Loom trust store.
public struct LoomTrustedDevice: Identifiable, Codable, Equatable {
    public let id: UUID
    public let name: String
    public let deviceType: DeviceType
    public let trustedAt: Date

    /// Creates a persisted trusted-device entry.
    ///
    /// - Parameters:
    ///   - id: Device identifier used during handshake.
    ///   - name: Display name shown in trust UI.
    ///   - deviceType: Platform type.
    ///   - trustedAt: Time the trust decision was granted.
    public init(id: UUID, name: String, deviceType: DeviceType, trustedAt: Date) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.trustedAt = trustedAt
    }
}

/// Stores trusted devices with persistence to UserDefaults.
@Observable
@MainActor
/// UserDefaults-backed trust persistence for manually trusted devices.
///
/// This type stores local trust grants and is commonly combined with a custom
/// ``LoomTrustProvider`` implementation for auto-trust policies.
public final class LoomTrustStore {
    /// Trusted devices (persisted to UserDefaults).
    public private(set) var trustedDevices: [LoomTrustedDevice] = []

    /// Flag to prevent saving during load.
    private var isLoading = false

    /// UserDefaults key for trusted devices.
    private let trustedDevicesKey: String

    /// Creates a trust store with a configurable storage key.
    /// - Parameter storageKey: UserDefaults key used for persistence.
    public init(storageKey: String = "LoomTrustedDevices") {
        trustedDevicesKey = storageKey
        loadTrustedDevices()
    }

    // MARK: - Persistence

    /// Load trusted devices from storage.
    public func loadTrustedDevices() {
        guard let data = UserDefaults.standard.data(forKey: trustedDevicesKey) else { return }
        do {
            // Avoid writing back while decoding persisted state.
            isLoading = true
            trustedDevices = try JSONDecoder().decode([LoomTrustedDevice].self, from: data)
            isLoading = false
            LoomLogger.trust("Loaded \(trustedDevices.count) trusted devices")
        } catch {
            isLoading = false
            LoomLogger.error(.trust, error: error, message: "Failed to load trusted devices: ")
        }
    }

    private func saveTrustedDevices() {
        guard !isLoading else { return }
        do {
            let data = try JSONEncoder().encode(trustedDevices)
            UserDefaults.standard.set(data, forKey: trustedDevicesKey)
            LoomLogger.trust("Saved \(trustedDevices.count) trusted devices")
        } catch {
            LoomLogger.error(.trust, error: error, message: "Failed to save trusted devices: ")
        }
    }

    // MARK: - Trust Operations

    /// Returns whether the provided device ID is trusted.
    /// - Parameter deviceID: The device identifier to check.
    public func isTrusted(deviceID: UUID) -> Bool {
        trustedDevices.contains { $0.id == deviceID }
    }

    /// Add a trusted device and persist it.
    /// - Parameter device: Trusted device to add.
    public func addTrustedDevice(_ device: LoomTrustedDevice) {
        trustedDevices.append(device)
        saveTrustedDevices()
    }

    /// Remove a trusted device and persist the update.
    /// - Parameter device: Trusted device to revoke.
    public func revokeTrust(for device: LoomTrustedDevice) {
        trustedDevices.removeAll { $0.id == device.id }
        saveTrustedDevices()
    }
}
