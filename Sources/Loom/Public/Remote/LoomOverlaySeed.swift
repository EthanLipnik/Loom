//
//  LoomOverlaySeed.swift
//  Loom
//
//  Created by Codex on 3/11/26.
//

import Foundation

/// Host seed used by ``LoomOverlayDirectory`` to probe for Loom peers off-LAN.
public struct LoomOverlaySeed: Hashable, Sendable {
    /// Host name or IP address reachable through an overlay or VPN path.
    public let host: String
    /// Optional port override for the peer's overlay probe listener.
    public let probePort: UInt16?

    public init(host: String, probePort: UInt16? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.probePort = probePort
    }
}
