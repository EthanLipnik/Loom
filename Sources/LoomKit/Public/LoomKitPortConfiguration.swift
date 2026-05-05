//
//  LoomKitPortConfiguration.swift
//  LoomKit
//
//  Created by Codex on 5/5/26.
//

import Foundation
import Loom

/// Listener ports requested by a LoomKit container.
public struct LoomKitPortConfiguration: Equatable, Sendable {
    /// TCP listener port used for Bonjour registration and TCP direct sessions.
    ///
    /// Use `0` to let the system assign an available ephemeral port.
    public let tcpPort: UInt16
    /// UDP listener port used for authenticated UDP direct sessions.
    ///
    /// Use `0` to let the system assign an available ephemeral port.
    public let udpPort: UInt16
    /// QUIC listener port used for authenticated QUIC direct sessions.
    ///
    /// Use `0` to let the system assign an available ephemeral port.
    public let quicPort: UInt16
    /// Overlay probe listener port used when ``LoomContainerConfiguration/overlayDirectory`` is enabled
    /// and the overlay directory configuration omits its own `probePort`.
    public let overlayProbePort: UInt16

    /// Creates a LoomKit port configuration.
    public init(
        tcpPort: UInt16 = 0,
        udpPort: UInt16 = 0,
        quicPort: UInt16 = 0,
        overlayProbePort: UInt16 = Loom.defaultOverlayProbePort
    ) {
        self.tcpPort = tcpPort
        self.udpPort = udpPort
        self.quicPort = quicPort
        self.overlayProbePort = overlayProbePort
    }

    /// Default LoomKit port behavior.
    public static let `default` = LoomKitPortConfiguration()
}
