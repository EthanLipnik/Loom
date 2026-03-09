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
    public static let version = "1.0.0"
    public static let protocolVersion: UInt8 = 2
    public static let serviceType = "_loom._tcp"
    public static let defaultControlPort: UInt16 = 9847
    public static let defaultDataPort: UInt16 = 9848
    public static let defaultMaxPacketSize = 1200
}
