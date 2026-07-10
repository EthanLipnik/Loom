//
//  LoomNetworkConfiguration.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Network

/// Configuration for network discovery and session transport behavior.
public struct LoomNetworkConfiguration: Sendable {
    public var serviceType: String
    public var controlPort: UInt16
    public var dataPort: UInt16
    public var udpPort: UInt16
    public var overlayProbePort: UInt16?
    public var maxPacketSize: Int
    public var enableBonjour: Bool
    public var enablePeerToPeer: Bool
    public var requireEncryptedMediaOnLocalNetwork: Bool
    public var enabledDirectTransports: Set<LoomTransportKind>
    public var directConnectionPolicy: LoomDirectConnectionPolicy
    public var directDatagramServiceClass: NWParameters.ServiceClass
    public var authenticatedSessionHandshakeTimeout: Duration
    public var authenticatedSessionTrustTimeout: Duration
    public var maxPendingAuthenticatedSessions: Int
    public var maximumConcurrentStreamsPerSession: Int
    public var maximumBufferedIncomingBytesPerStream: Int
    public var maximumBufferedIncomingPayloadsPerStream: Int
    public var maximumBufferedIncomingBytesPerSession: Int
    public var maximumBufferedIncomingPayloadsPerSession: Int
    public var maximumActiveAuthenticatedSessions: Int
    public var maximumBufferedIncomingBytesPerNode: Int
    public var maximumBufferedIncomingPayloadsPerNode: Int

    public init(
        serviceType: String = Loom.serviceType,
        controlPort: UInt16 = 0,
        dataPort: UInt16 = 0,
        udpPort: UInt16 = 0,
        overlayProbePort: UInt16? = nil,
        maxPacketSize: Int = Loom.defaultMaxPacketSize,
        enableBonjour: Bool = true,
        enablePeerToPeer: Bool = true,
        requireEncryptedMediaOnLocalNetwork: Bool = false,
        enabledDirectTransports: Set<LoomTransportKind> = Set(LoomTransportKind.allCases),
        directConnectionPolicy: LoomDirectConnectionPolicy = .default,
        directDatagramServiceClass: NWParameters.ServiceClass = .interactiveVideo,
        authenticatedSessionHandshakeTimeout: Duration = .seconds(10),
        authenticatedSessionTrustTimeout: Duration = .seconds(120),
        maxPendingAuthenticatedSessions: Int = 32,
        maximumConcurrentStreamsPerSession: Int = 256,
        maximumBufferedIncomingBytesPerStream: Int = LoomMessageLimits.maxReceiveBufferBytes,
        maximumBufferedIncomingPayloadsPerStream: Int = LoomMessageLimits.maxBufferedPayloadsPerStream,
        maximumBufferedIncomingBytesPerSession: Int = LoomMessageLimits.maxBufferedIncomingBytesPerSession,
        maximumBufferedIncomingPayloadsPerSession: Int = LoomMessageLimits.maxBufferedPayloadsPerSession,
        maximumActiveAuthenticatedSessions: Int = 32,
        maximumBufferedIncomingBytesPerNode: Int = LoomMessageLimits.maxBufferedIncomingBytesPerNode,
        maximumBufferedIncomingPayloadsPerNode: Int = LoomMessageLimits.maxBufferedPayloadsPerNode
    ) {
        self.serviceType = serviceType
        self.controlPort = controlPort
        self.dataPort = dataPort
        self.udpPort = udpPort
        self.overlayProbePort = overlayProbePort
        self.maxPacketSize = maxPacketSize
        self.enableBonjour = enableBonjour
        self.enablePeerToPeer = enablePeerToPeer
        self.requireEncryptedMediaOnLocalNetwork = requireEncryptedMediaOnLocalNetwork
        self.enabledDirectTransports = enabledDirectTransports
        self.directConnectionPolicy = directConnectionPolicy
        self.directDatagramServiceClass = directDatagramServiceClass
        self.authenticatedSessionHandshakeTimeout = max(.milliseconds(1), authenticatedSessionHandshakeTimeout)
        self.authenticatedSessionTrustTimeout = max(.milliseconds(1), authenticatedSessionTrustTimeout)
        self.maxPendingAuthenticatedSessions = max(1, maxPendingAuthenticatedSessions)
        self.maximumConcurrentStreamsPerSession = max(1, maximumConcurrentStreamsPerSession)
        self.maximumBufferedIncomingBytesPerStream = max(1, maximumBufferedIncomingBytesPerStream)
        self.maximumBufferedIncomingPayloadsPerStream = max(1, maximumBufferedIncomingPayloadsPerStream)
        self.maximumBufferedIncomingBytesPerSession = max(1, maximumBufferedIncomingBytesPerSession)
        self.maximumBufferedIncomingPayloadsPerSession = max(1, maximumBufferedIncomingPayloadsPerSession)
        self.maximumActiveAuthenticatedSessions = max(1, maximumActiveAuthenticatedSessions)
        self.maximumBufferedIncomingBytesPerNode = max(1, maximumBufferedIncomingBytesPerNode)
        self.maximumBufferedIncomingPayloadsPerNode = max(1, maximumBufferedIncomingPayloadsPerNode)
    }

    public init(
        serviceType: String = Loom.serviceType,
        controlPort: UInt16 = 0,
        dataPort: UInt16 = 0,
        udpPort: UInt16 = 0,
        overlayProbePort: UInt16? = nil,
        maxPacketSize: Int = Loom.defaultMaxPacketSize,
        enableBonjour: Bool = true,
        enablePeerToPeer: Bool = true,
        requireEncryptedMediaOnLocalNetwork: Bool = false,
        enabledDirectTransports: Set<LoomTransportKind>,
        directDatagramServiceClass: NWParameters.ServiceClass = .interactiveVideo
    ) {
        self.init(
            serviceType: serviceType,
            controlPort: controlPort,
            dataPort: dataPort,
            udpPort: udpPort,
            overlayProbePort: overlayProbePort,
            maxPacketSize: maxPacketSize,
            enableBonjour: enableBonjour,
            enablePeerToPeer: enablePeerToPeer,
            requireEncryptedMediaOnLocalNetwork: requireEncryptedMediaOnLocalNetwork,
            enabledDirectTransports: enabledDirectTransports,
            directConnectionPolicy: .default,
            directDatagramServiceClass: directDatagramServiceClass
        )
    }

    public init(
        serviceType: String = Loom.serviceType,
        controlPort: UInt16 = 0,
        dataPort: UInt16 = 0,
        udpPort: UInt16 = 0,
        maxPacketSize: Int = Loom.defaultMaxPacketSize,
        enableBonjour: Bool = true,
        enablePeerToPeer: Bool = true,
        requireEncryptedMediaOnLocalNetwork: Bool = false,
        enabledDirectTransports: Set<LoomTransportKind>,
        directDatagramServiceClass: NWParameters.ServiceClass = .interactiveVideo
    ) {
        self.init(
            serviceType: serviceType,
            controlPort: controlPort,
            dataPort: dataPort,
            udpPort: udpPort,
            overlayProbePort: nil,
            maxPacketSize: maxPacketSize,
            enableBonjour: enableBonjour,
            enablePeerToPeer: enablePeerToPeer,
            requireEncryptedMediaOnLocalNetwork: requireEncryptedMediaOnLocalNetwork,
            enabledDirectTransports: enabledDirectTransports,
            directConnectionPolicy: .default,
            directDatagramServiceClass: directDatagramServiceClass
        )
    }

    public static let `default` = LoomNetworkConfiguration()
}
