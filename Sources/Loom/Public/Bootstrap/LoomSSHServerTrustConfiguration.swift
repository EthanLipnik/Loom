//
//  LoomSSHServerTrustConfiguration.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CryptoKit
import Foundation
import NIOSSH

/// SSH host-certificate trust failures.
public enum LoomSSHServerTrustError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case missingHostCertificate
    case invalidHostCertificate(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            "SSH server trust configuration is invalid: \(detail)"
        case .missingHostCertificate:
            "The SSH server did not present an OpenSSH host certificate."
        case let .invalidHostCertificate(detail):
            "The SSH host certificate is not trusted: \(detail)"
        }
    }
}

/// SSH server trust configuration shared by Loom bootstrap and emergency shell flows.
public struct LoomSSHServerTrustConfiguration: Sendable, Equatable, Codable {
    /// Canonical OpenSSH public keys for the host CAs trusted by the client.
    public let trustedHostAuthorities: [String]

    /// Required SSH host principal, typically derived from the Loom device ID.
    public let requiredPrincipal: String

    /// SHA256 fingerprints for raw SSH host keys trusted by the client.
    public let trustedHostKeyFingerprints: [String]

    public init(
        trustedHostAuthorities: [String],
        requiredPrincipal: String,
        trustedHostKeyFingerprints: [String] = []
    ) {
        self.trustedHostAuthorities = trustedHostAuthorities
        self.requiredPrincipal = requiredPrincipal
        self.trustedHostKeyFingerprints = trustedHostKeyFingerprints
    }

    private enum CodingKeys: String, CodingKey {
        case trustedHostAuthorities
        case requiredPrincipal
        case trustedHostKeyFingerprints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trustedHostAuthorities = try container.decode(
            [String].self,
            forKey: .trustedHostAuthorities
        )
        requiredPrincipal = try container.decode(String.self, forKey: .requiredPrincipal)
        trustedHostKeyFingerprints = try container.decodeIfPresent(
            [String].self,
            forKey: .trustedHostKeyFingerprints
        ) ?? []
    }

    /// Returns the canonical Loom SSH host principal for a device ID.
    public static func requiredPrincipal(for deviceID: UUID) -> String {
        "loom-device/\(deviceID.uuidString.lowercased())"
    }
}

/// Diagnostics emitted after a host certificate has been validated.
public struct LoomSSHValidatedHostCertificate: Sendable, Equatable {
    public let keyID: String
    public let principal: String
    public let hostKeyFingerprint: String

    public init(keyID: String, principal: String, hostKeyFingerprint: String) {
        self.keyID = keyID
        self.principal = principal
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

/// Shared validator for OpenSSH host certificates used by Loom-managed SSH flows.
public struct LoomSSHServerTrustValidator: Sendable {
    public let configuration: LoomSSHServerTrustConfiguration

    private let authorityKeys: [NIOSSHPublicKey]
    private let trustedHostKeyFingerprints: Set<String>

    public init(configuration: LoomSSHServerTrustConfiguration) throws {
        let requiredPrincipal = configuration.requiredPrincipal
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let authorities = configuration.trustedHostAuthorities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fingerprints = configuration.trustedHostKeyFingerprints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !authorities.isEmpty || !fingerprints.isEmpty else {
            throw LoomSSHServerTrustError.invalidConfiguration(
                "At least one host CA key or pinned host-key fingerprint is required."
            )
        }
        if !authorities.isEmpty, requiredPrincipal.isEmpty {
            throw LoomSSHServerTrustError.invalidConfiguration(
                "Required principal must not be empty when host CAs are used."
            )
        }

        do {
            authorityKeys = try authorities.map { authority in
                try NIOSSHPublicKey(openSSHPublicKey: authority)
            }
        } catch {
            throw LoomSSHServerTrustError.invalidConfiguration(
                "One or more trusted host CA public keys are invalid."
            )
        }

        self.configuration = LoomSSHServerTrustConfiguration(
            trustedHostAuthorities: authorities,
            requiredPrincipal: requiredPrincipal,
            trustedHostKeyFingerprints: fingerprints
        )
        trustedHostKeyFingerprints = Set(fingerprints)
    }

    /// Validates a presented SSH host key and returns diagnostics about the certified leaf key.
    public func validate(hostKey: NIOSSHPublicKey) throws -> LoomSSHValidatedHostCertificate {
        if let certifiedHostKey = NIOSSHCertifiedPublicKey(hostKey) {
            let fingerprint = try Self.hostKeyFingerprint(for: certifiedHostKey.key)
            if trustedHostKeyFingerprints.contains(fingerprint) {
                LoomLogger.ssh(
                    "Validated SSH host certificate using pinned leaf key \(fingerprint)"
                )
                return LoomSSHValidatedHostCertificate(
                    keyID: certifiedHostKey.keyID,
                    principal: configuration.requiredPrincipal,
                    hostKeyFingerprint: fingerprint
                )
            }

            guard !authorityKeys.isEmpty else {
                throw LoomSSHServerTrustError.invalidHostCertificate(
                    "The SSH host certificate leaf key is not pinned."
                )
            }

            do {
                _ = try certifiedHostKey.validate(
                    principal: configuration.requiredPrincipal,
                    type: .host,
                    allowedAuthoritySigningKeys: authorityKeys,
                    acceptableCriticalOptions: []
                )
                guard certifiedHostKey.validPrincipals == [configuration.requiredPrincipal] else {
                    throw LoomSSHServerTrustError.invalidHostCertificate(
                        "The certificate must contain exactly the required Loom principal."
                    )
                }

                LoomLogger.ssh(
                    "Validated SSH host certificate for \(configuration.requiredPrincipal) using leaf key \(fingerprint)"
                )
                return LoomSSHValidatedHostCertificate(
                    keyID: certifiedHostKey.keyID,
                    principal: configuration.requiredPrincipal,
                    hostKeyFingerprint: fingerprint
                )
            } catch let error as LoomSSHServerTrustError {
                throw error
            } catch {
                throw LoomSSHServerTrustError.invalidHostCertificate(error.localizedDescription)
            }
        }

        let fingerprint = try Self.hostKeyFingerprint(for: hostKey)
        if trustedHostKeyFingerprints.contains(fingerprint) {
            LoomLogger.ssh(
                "Validated raw SSH host key using pinned fingerprint \(fingerprint)"
            )
            return LoomSSHValidatedHostCertificate(
                keyID: "",
                principal: configuration.requiredPrincipal,
                hostKeyFingerprint: fingerprint
            )
        }

        throw LoomSSHServerTrustError.missingHostCertificate
    }

    public static func hostKeyFingerprint(for hostKey: NIOSSHPublicKey) throws -> String {
        let openSSH = String(openSSHPublicKey: hostKey)
        let components = openSSH.split(separator: " ")
        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1])) else {
            throw LoomSSHServerTrustError.invalidHostCertificate(
                "Failed to derive the SSH host-key fingerprint."
            )
        }

        let digest = SHA256.hash(data: keyData)
        let fingerprint = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(fingerprint)"
    }
}
