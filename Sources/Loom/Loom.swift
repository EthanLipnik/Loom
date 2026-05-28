//
//  Loom.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

@_exported import Foundation

package typealias WindowID = UInt32
package typealias StreamID = UInt16
package typealias StreamSessionID = UUID

public enum Loom {
    public static let version = "2.0.3"
    public static let protocolVersion: UInt8 = 3
    /// Default Bonjour service type for peer discovery.
    ///
    /// Uses a `_tcp` suffix because `NWConnection` cannot resolve `_udp`
    /// Bonjour service endpoints reliably. Authenticated sessions publish
    /// their direct TCP, UDP, and QUIC ports in TXT metadata.
    public static let serviceType = "_loom._tcp"
    public static let defaultControlPort: UInt16 = 9847
    public static let defaultDataPort: UInt16 = 9848
    public static let defaultOverlayProbePort: UInt16 = 9850
    public static let defaultMaxPacketSize = 1200
}
