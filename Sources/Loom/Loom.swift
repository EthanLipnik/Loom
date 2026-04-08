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
    public static let version = "1.7.0"
    public static let protocolVersion: UInt8 = 2
    /// Default Bonjour service type for peer discovery.
    ///
    /// Uses `_tcp` suffix despite actual sessions running over UDP because
    /// `NWConnection` cannot resolve `_udp` Bonjour service endpoints
    /// (the connection times out during DNS-SD resolution). The TCP
    /// `NWListener` in ``BonjourAdvertiser`` exists only for service
    /// registration — no TCP connections are established. Clients read
    /// the UDP port from the TXT record and connect directly.
    public static let serviceType = "_loom._tcp"
    public static let defaultControlPort: UInt16 = 9847
    public static let defaultDataPort: UInt16 = 9848
    public static let defaultOverlayProbePort: UInt16 = 9850
    public static let defaultMaxPacketSize = 1200
}
