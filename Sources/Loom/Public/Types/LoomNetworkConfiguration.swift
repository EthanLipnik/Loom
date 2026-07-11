//
//  LoomNetworkConfiguration.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
#if canImport(Network)
import Network
#endif

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
    /// Backend-independent traffic class used for direct datagram transports.
    public var backendDirectDatagramServiceClass: LoomNetworkServiceClass
#if canImport(Network)
    /// Network.framework compatibility projection of the direct datagram traffic class.
    public var directDatagramServiceClass: NWParameters.ServiceClass {
        get { backendDirectDatagramServiceClass.nwServiceClass ?? .bestEffort }
        set { backendDirectDatagramServiceClass = LoomNetworkServiceClass(newValue) }
    }
#endif
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

#if canImport(Network)
    /// Creates a configuration using backend-independent network values.
    ///
    /// On Apple platforms, the source-compatible Network.framework initializer
    /// remains available as an overload.
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
        backendDirectDatagramServiceClass: LoomNetworkServiceClass,
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
        self.backendDirectDatagramServiceClass = backendDirectDatagramServiceClass
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
#endif

#if canImport(Network)
    /// Creates a configuration using the released Network.framework service-class API.
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
            directConnectionPolicy: directConnectionPolicy,
            backendDirectDatagramServiceClass: LoomNetworkServiceClass(directDatagramServiceClass),
            authenticatedSessionHandshakeTimeout: authenticatedSessionHandshakeTimeout,
            authenticatedSessionTrustTimeout: authenticatedSessionTrustTimeout,
            maxPendingAuthenticatedSessions: maxPendingAuthenticatedSessions,
            maximumConcurrentStreamsPerSession: maximumConcurrentStreamsPerSession,
            maximumBufferedIncomingBytesPerStream: maximumBufferedIncomingBytesPerStream,
            maximumBufferedIncomingPayloadsPerStream: maximumBufferedIncomingPayloadsPerStream,
            maximumBufferedIncomingBytesPerSession: maximumBufferedIncomingBytesPerSession,
            maximumBufferedIncomingPayloadsPerSession: maximumBufferedIncomingPayloadsPerSession,
            maximumActiveAuthenticatedSessions: maximumActiveAuthenticatedSessions,
            maximumBufferedIncomingBytesPerNode: maximumBufferedIncomingBytesPerNode,
            maximumBufferedIncomingPayloadsPerNode: maximumBufferedIncomingPayloadsPerNode
        )
    }
#else
    /// Creates a configuration with Loom's default backend-independent traffic class.
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
        backendDirectDatagramServiceClass: LoomNetworkServiceClass = .interactiveVideo,
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
        self.backendDirectDatagramServiceClass = backendDirectDatagramServiceClass
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
#endif

#if canImport(Network)
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
#endif

#if canImport(Network)
    public static let `default` = LoomNetworkConfiguration()
#else
    public static let `default` = LoomNetworkConfiguration(
        backendDirectDatagramServiceClass: .interactiveVideo
    )
#endif
}
