//
//  LoomTransportKind.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import LoomNetworking

/// Direct transport kinds supported by Loom session establishment.
public enum LoomTransportKind: String, Codable, CaseIterable, Sendable {
    case tcp
    case quic
    case udp
}

package extension LoomTransportKind {
    init(_ networkTransportKind: LoomNetworking.LoomTransportKind) {
        switch networkTransportKind {
        case .tcp:
            self = .tcp
        case .quic:
            self = .quic
        case .udp:
            self = .udp
        }
    }

    var networkTransportKind: LoomNetworking.LoomTransportKind {
        switch self {
        case .tcp:
            .tcp
        case .quic:
            .quic
        case .udp:
            .udp
        }
    }

    var directConnectionRank: Int {
        switch self {
        case .udp:
            return 0
        case .quic:
            return 1
        case .tcp:
            return 2
        }
    }

    var usesDatagramPath: Bool {
        switch self {
        case .udp, .quic:
            return true
        case .tcp:
            return false
        }
    }
}
