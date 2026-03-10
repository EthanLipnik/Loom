//
//  LoomDeviceProfile.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import Foundation

/// App-owned device metadata used to build Loom advertisements and hello requests.
public struct LoomDeviceProfile: Sendable, Equatable {
    public let deviceID: UUID
    public let deviceName: String
    public let deviceType: DeviceType
    public let iCloudUserID: String?
    public let additionalAdvertisementMetadata: [String: String]
    public let additionalSupportedFeatures: [String]

    public init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        iCloudUserID: String? = nil,
        additionalAdvertisementMetadata: [String: String] = [:],
        additionalSupportedFeatures: [String] = []
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.iCloudUserID = iCloudUserID
        self.additionalAdvertisementMetadata = additionalAdvertisementMetadata
        self.additionalSupportedFeatures = additionalSupportedFeatures
    }

    public func makeAdvertisement(
        identityKeyID: String? = nil,
        directTransports: [LoomDirectTransportAdvertisement] = [],
        metadataTransform: (([String: String]) throws -> [String: String])? = nil
    ) throws -> LoomPeerAdvertisement {
        var metadata = additionalAdvertisementMetadata
        if let metadataTransform {
            metadata = try metadataTransform(metadata)
        }
        return LoomPeerAdvertisement(
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceType: deviceType,
            directTransports: directTransports,
            metadata: metadata
        )
    }

    public func makeHelloRequest(
        identityKeyID: String? = nil,
        directTransports: [LoomDirectTransportAdvertisement] = [],
        metadataTransform: (([String: String]) throws -> [String: String])? = nil
    ) throws -> LoomSessionHelloRequest {
        let advertisement = try makeAdvertisement(
            identityKeyID: identityKeyID,
            directTransports: directTransports,
            metadataTransform: metadataTransform
        )
        return LoomSessionHelloRequest(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: deviceType,
            advertisement: advertisement,
            supportedFeatures: supportedFeatures,
            iCloudUserID: iCloudUserID
        )
    }

    public var supportedFeatures: [String] {
        var features = Set(LoomSessionHelloRequest.defaultFeatures)
        for feature in additionalSupportedFeatures {
            let trimmed = feature.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            features.insert(trimmed)
        }
        return features.sorted()
    }
}
