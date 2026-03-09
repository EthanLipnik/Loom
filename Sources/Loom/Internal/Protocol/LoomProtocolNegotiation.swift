//
//  LoomProtocolNegotiation.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Protocol capability negotiation primitives for hello handshake.
//

import Foundation

package struct LoomFeatureSet: OptionSet, Sendable, Codable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Endpoints support registry-based control-message dispatch.
    package static let controlMessageRouting = LoomFeatureSet(rawValue: 1 << 0)
    /// Endpoints support typed hello negotiation fields.
    package static let protocolNegotiation = LoomFeatureSet(rawValue: 1 << 1)
    /// Endpoints enforce signed identity handshake metadata.
    package static let identityAuthV2 = LoomFeatureSet(rawValue: 1 << 2)
    /// Endpoints support authenticated UDP registration tokens.
    package static let udpRegistrationAuthV1 = LoomFeatureSet(rawValue: 1 << 3)
    /// Endpoints support end-to-end encrypted media payloads.
    package static let encryptedMediaV1 = LoomFeatureSet(rawValue: 1 << 4)
}

package struct LoomProtocolNegotiation: Codable, Sendable {
    package let protocolVersion: Int
    package let supportedFeatures: LoomFeatureSet
    package let selectedFeatures: LoomFeatureSet

    package init(
        protocolVersion: Int,
        supportedFeatures: LoomFeatureSet,
        selectedFeatures: LoomFeatureSet
    ) {
        self.protocolVersion = protocolVersion
        self.supportedFeatures = supportedFeatures
        self.selectedFeatures = selectedFeatures
    }

    package static func clientHello(
        protocolVersion: Int,
        supportedFeatures: LoomFeatureSet
    )
    -> LoomProtocolNegotiation {
        LoomProtocolNegotiation(
            protocolVersion: protocolVersion,
            supportedFeatures: supportedFeatures,
            selectedFeatures: []
        )
    }
}
