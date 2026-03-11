//
//  LoomNetworkConfiguration.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation

/// Configuration for network discovery and session transport behavior.
public struct LoomNetworkConfiguration: Sendable {
    public var serviceType: String
    public var controlPort: UInt16
    public var dataPort: UInt16
    public var quicPort: UInt16
    public var overlayProbePort: UInt16?
    public var maxPacketSize: Int
    public var enablePeerToPeer: Bool
    public var requireEncryptedMediaOnLocalNetwork: Bool
    public var enabledDirectTransports: Set<LoomTransportKind>
    public var directConnectionPolicy: LoomDirectConnectionPolicy

    public init(
        serviceType: String = Loom.serviceType,
        controlPort: UInt16 = 0,
        dataPort: UInt16 = 0,
        quicPort: UInt16 = 0,
        overlayProbePort: UInt16? = nil,
        maxPacketSize: Int = Loom.defaultMaxPacketSize,
        enablePeerToPeer: Bool = true,
        requireEncryptedMediaOnLocalNetwork: Bool = false,
        enabledDirectTransports: Set<LoomTransportKind> = Set(LoomTransportKind.allCases),
        directConnectionPolicy: LoomDirectConnectionPolicy = .default
    ) {
        self.serviceType = serviceType
        self.controlPort = controlPort
        self.dataPort = dataPort
        self.quicPort = quicPort
        self.overlayProbePort = overlayProbePort
        self.maxPacketSize = maxPacketSize
        self.enablePeerToPeer = enablePeerToPeer
        self.requireEncryptedMediaOnLocalNetwork = requireEncryptedMediaOnLocalNetwork
        self.enabledDirectTransports = enabledDirectTransports
        self.directConnectionPolicy = directConnectionPolicy
    }

    public init(
        serviceType: String = Loom.serviceType,
        controlPort: UInt16 = 0,
        dataPort: UInt16 = 0,
        quicPort: UInt16 = 0,
        overlayProbePort: UInt16? = nil,
        maxPacketSize: Int = Loom.defaultMaxPacketSize,
        enablePeerToPeer: Bool = true,
        requireEncryptedMediaOnLocalNetwork: Bool = false,
        enabledDirectTransports: Set<LoomTransportKind>
    ) {
        self.init(
            serviceType: serviceType,
            controlPort: controlPort,
            dataPort: dataPort,
            quicPort: quicPort,
            overlayProbePort: overlayProbePort,
            maxPacketSize: maxPacketSize,
            enablePeerToPeer: enablePeerToPeer,
            requireEncryptedMediaOnLocalNetwork: requireEncryptedMediaOnLocalNetwork,
            enabledDirectTransports: enabledDirectTransports,
            directConnectionPolicy: .default
        )
    }

    public init(
        serviceType: String = Loom.serviceType,
        controlPort: UInt16 = 0,
        dataPort: UInt16 = 0,
        quicPort: UInt16 = 0,
        maxPacketSize: Int = Loom.defaultMaxPacketSize,
        enablePeerToPeer: Bool = true,
        requireEncryptedMediaOnLocalNetwork: Bool = false,
        enabledDirectTransports: Set<LoomTransportKind>
    ) {
        self.init(
            serviceType: serviceType,
            controlPort: controlPort,
            dataPort: dataPort,
            quicPort: quicPort,
            overlayProbePort: nil,
            maxPacketSize: maxPacketSize,
            enablePeerToPeer: enablePeerToPeer,
            requireEncryptedMediaOnLocalNetwork: requireEncryptedMediaOnLocalNetwork,
            enabledDirectTransports: enabledDirectTransports,
            directConnectionPolicy: .default
        )
    }

    public static let `default` = LoomNetworkConfiguration()
}
