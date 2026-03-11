//
//  LoomHostSharedTypes.swift
//  LoomHost
//
//  Created by Codex on 3/10/26.
//

import Foundation
import Loom

package enum LoomHostPeerSource: String, Codable, Sendable {
    case nearby
    case overlay
    case cloudKitOwn
    case cloudKitShared
    case relay
}

package struct LoomHostPeerRecord: Codable, Hashable, Sendable, Identifiable {
    package let id: LoomPeerID
    package let name: String
    package let deviceType: DeviceType
    package let sources: [LoomHostPeerSource]
    package let isNearby: Bool
    package let isShared: Bool
    package let remoteAccessEnabled: Bool
    package let relaySessionID: String?
    package let advertisement: LoomPeerAdvertisement
    package let bootstrapMetadata: LoomBootstrapMetadata?
    package let lastSeen: Date
}

package struct LoomHostStateSnapshot: Codable, Sendable {
    package let peers: [LoomHostPeerRecord]
    package let isRunning: Bool
    package let isRemoteHosting: Bool
    package let lastErrorMessage: String?
}

package struct LoomHostConnectionDescriptor: Codable, Sendable {
    package let connectionID: UUID
    package let peer: LoomHostPeerRecord
    package let context: LoomAuthenticatedSessionContext
}

package enum LoomHostReplyStatus: Codable, Sendable {
    case ok
    case failed(String)
}

package enum LoomHostIPCMessage: Codable, Sendable {
    case register(clientID: UUID, app: LoomHostAppDescriptor)
    case unregister(clientID: UUID)
    case refreshPeers(clientID: UUID)
    case startRemoteHosting(clientID: UUID, sessionID: String, publicHostForTCP: String?)
    case stopRemoteHosting(clientID: UUID)
    case connect(clientID: UUID, peerID: LoomPeerID)
    case connectRemote(clientID: UUID, sessionID: String)
    case disconnect(clientID: UUID, connectionID: UUID)
    case openStream(clientID: UUID, connectionID: UUID, streamID: UInt16, label: String?)
    case streamData(clientID: UUID, connectionID: UUID, streamID: UInt16, payloadBase64: String)
    case closeStream(clientID: UUID, connectionID: UUID, streamID: UInt16)

    case reply(status: LoomHostReplyStatus)
    case registered(snapshot: LoomHostStateSnapshot)
    case stateChanged(snapshot: LoomHostStateSnapshot)
    case connected(LoomHostConnectionDescriptor)
    case incomingConnection(LoomHostConnectionDescriptor)
    case connectionStateChanged(connectionID: UUID, state: LoomAuthenticatedSessionState, errorMessage: String?)
    case streamOpened(connectionID: UUID, streamID: UInt16, label: String?)
    case streamDataReceived(connectionID: UUID, streamID: UInt16, payloadBase64: String)
    case streamClosed(connectionID: UUID, streamID: UInt16)
}

package struct LoomHostIPCFrame: Codable, Sendable {
    package let requestID: UUID?
    package let message: LoomHostIPCMessage
}

package enum LoomHostError: LocalizedError, Sendable {
    case unsupportedPlatform
    case invalidSharedContainer(String)
    case socketPathTooLong
    case brokerUnavailable
    case protocolViolation(String)
    case remoteFailure(String)
    case peerNotFound(LoomPeerID)
    case connectionNotFound(UUID)
    case appNotRegistered(String)

    package init(_ message: String) {
        self = .protocolViolation(message)
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Shared-host mode is only available on macOS."
        case let .invalidSharedContainer(message):
            message
        case .socketPathTooLong:
            "The shared-host Unix socket path exceeds the platform limit."
        case .brokerUnavailable:
            "The shared-host broker is unavailable."
        case let .protocolViolation(message):
            message
        case let .remoteFailure(message):
            message
        case let .peerNotFound(peerID):
            "The shared-host broker could not resolve peer \(peerID.rawValue)."
        case let .connectionNotFound(connectionID):
            "The shared-host broker could not resolve connection \(connectionID.uuidString)."
        case let .appNotRegistered(appID):
            "The shared-host broker could not find a registered app for \(appID)."
        }
    }
}
