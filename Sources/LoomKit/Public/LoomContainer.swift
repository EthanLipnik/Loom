//
//  LoomContainer.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

import Foundation
import Loom
import LoomCloudKit
import LoomHost

/// Shared LoomKit runtime container modeled after SwiftData's `ModelContainer`.
@MainActor
public final class LoomContainer {
    /// Normalized configuration used to construct the shared runtime stack.
    public let configuration: LoomContainerConfiguration
    /// Default main-actor context injected into SwiftUI environment values.
    public let mainContext: LoomContext

    private let store: LoomStore

    /// Creates a SwiftUI-first LoomKit container and its shared runtime stack.
    public init(for configuration: LoomContainerConfiguration) throws {
        let trimmedServiceType = configuration.serviceType.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedServiceName = configuration.serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServiceType.isEmpty else {
            throw LoomKitError(message: "LoomKit service type must not be empty.")
        }
        guard !trimmedServiceName.isEmpty else {
            throw LoomKitError(message: "LoomKit service name must not be empty.")
        }

        self.configuration = LoomContainerConfiguration(
            serviceType: trimmedServiceType,
            serviceName: trimmedServiceName,
            deviceIDSuiteName: configuration.deviceIDSuiteName,
            cloudKit: configuration.cloudKit,
            overlayDirectory: configuration.overlayDirectory,
            relay: configuration.relay,
            sharedHost: configuration.sharedHost,
            trust: configuration.trust,
            enablePeerToPeer: configuration.enablePeerToPeer,
            advertisementMetadata: configuration.advertisementMetadata,
            supportedFeatures: configuration.supportedFeatures,
            bootstrapMetadataProvider: configuration.bootstrapMetadataProvider,
            remoteSessionID: configuration.remoteSessionID,
            transferConfiguration: configuration.transferConfiguration,
            directConnectionPolicy: configuration.directConnectionPolicy
        )

        let deviceID = LoomSharedDeviceID.getOrCreate(
            suiteName: configuration.deviceIDSuiteName
        )
        let networkConfiguration = LoomNetworkConfiguration(
            serviceType: trimmedServiceType,
            overlayProbePort: configuration.overlayDirectory?.probePort,
            enablePeerToPeer: configuration.enablePeerToPeer,
            directConnectionPolicy: configuration.directConnectionPolicy
        )
        let trustStore = LoomTrustStore(suiteName: configuration.deviceIDSuiteName)
        let node = LoomNode(
            configuration: networkConfiguration,
            identityManager: LoomIdentityManager.shared
        )
        let relayClient = configuration.relay.map { LoomRelayClient(configuration: $0) }
        let cloudKitConfiguration = configuration.cloudKit.map {
            Self.resolvedCloudKitConfiguration(
                $0,
                deviceIDSuiteName: configuration.deviceIDSuiteName
            )
        }
        let cloudKitManager = cloudKitConfiguration.map(LoomCloudKitManager.init(configuration:))
        let peerProvider = cloudKitManager.map(LoomCloudKitPeerProvider.init(cloudKitManager:))
        let shareManager = cloudKitManager.map { LoomCloudKitShareManager(cloudKitManager: $0) }

        if let cloudKitManager {
            node.trustProvider = LoomCloudKitTrustProvider(
                cloudKitManager: cloudKitManager,
                localTrustStore: trustStore,
                trustMode: Self.cloudKitTrustMode(for: configuration.trust)
            )
        } else {
            node.trustProvider = LoomLocalTrustProvider(trustStore: trustStore)
        }

        let connectionCoordinator = LoomConnectionCoordinator(
            node: node,
            relayClient: relayClient,
            policy: configuration.directConnectionPolicy
        )
        let bootstrapMetadataProvider = self.configuration.bootstrapMetadataProvider
        let hostAdvertisementMetadata = self.configuration.advertisementMetadata
        let hostSupportedFeatures = self.configuration.supportedFeatures
        let overlayDirectoryConfiguration = self.configuration.overlayDirectory
        let hostClient: LoomHostClient?
        #if os(macOS)
        if let sharedHost = self.configuration.sharedHost {
            hostClient = LoomHostClient(
                configuration: sharedHost,
                runtimeFactory: {
                    LoomHostRuntimeDependencies(
                        serviceName: trimmedServiceName,
                        deviceID: deviceID,
                        node: node,
                        cloudKitManager: cloudKitManager,
                        peerProvider: peerProvider,
                        shareManager: shareManager,
                        relayClient: relayClient,
                        overlayDirectoryConfiguration: overlayDirectoryConfiguration,
                        connectionCoordinator: connectionCoordinator,
                        bootstrapMetadataProvider: bootstrapMetadataProvider,
                        hostAdvertisementMetadata: hostAdvertisementMetadata,
                        hostSupportedFeatures: hostSupportedFeatures
                    )
                }
            )
        } else {
            hostClient = nil
        }
        #else
        let hostClient: LoomHostClient? = nil
        #endif
        store = LoomStore(
            configuration: self.configuration,
            deviceID: deviceID,
            node: node,
            trustStore: trustStore,
            cloudKitManager: cloudKitManager,
            peerProvider: peerProvider,
            shareManager: shareManager,
            relayClient: relayClient,
            connectionCoordinator: connectionCoordinator,
            hostClient: hostClient
        )
        mainContext = LoomContext(store: store)
    }

    /// Creates another context backed by the same shared LoomKit store.
    public func makeContext() -> LoomContext {
        LoomContext(store: store)
    }

    static let environmentFallback: LoomContainer = try! LoomContainer(
        for: LoomContainerConfiguration(
            serviceName: "Loom"
        )
    )

    private static func cloudKitTrustMode(for trustMode: LoomTrustMode) -> LoomCloudKitTrustMode {
        switch trustMode {
        case .manualOnly:
            .manualOnly
        case .sameAccountAutoTrust:
            .sameAccountAutoTrust
        case .shareAwareAutoTrust:
            .shareAwareAutoTrust
        }
    }

    private static func resolvedCloudKitConfiguration(
        _ configuration: LoomCloudKitConfiguration,
        deviceIDSuiteName: String?
    ) -> LoomCloudKitConfiguration {
        LoomCloudKitConfiguration(
            containerIdentifier: configuration.containerIdentifier,
            deviceRecordType: configuration.deviceRecordType,
            peerRecordType: configuration.peerRecordType,
            peerZoneName: configuration.peerZoneName,
            participantIdentityRecordType: configuration.participantIdentityRecordType,
            shareTitle: configuration.shareTitle,
            deviceIDKey: configuration.deviceIDKey,
            deviceIDSuiteName: configuration.deviceIDSuiteName ?? deviceIDSuiteName,
            shareParticipantCacheTTL: configuration.shareParticipantCacheTTL
        )
    }
}
