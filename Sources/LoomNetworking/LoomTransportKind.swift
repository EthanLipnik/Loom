//
//  LoomTransportKind.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation

/// Direct transport kinds supported by Loom session establishment.
public enum LoomTransportKind: String, Codable, CaseIterable, Sendable {
    case tcp
    case quic
    case udp
}
