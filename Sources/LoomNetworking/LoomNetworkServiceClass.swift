//
//  LoomNetworkServiceClass.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// A backend-independent traffic service class.
///
/// The raw values are stable Loom vocabulary. Platform backends map them to
/// their closest supported quality-of-service or traffic-class primitive.
public struct LoomNetworkServiceClass: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let bestEffort = LoomNetworkServiceClass(rawValue: "best-effort")
    public static let background = LoomNetworkServiceClass(rawValue: "background")
    public static let interactiveVideo = LoomNetworkServiceClass(rawValue: "interactive-video")
    public static let interactiveVoice = LoomNetworkServiceClass(rawValue: "interactive-voice")
    public static let responsiveData = LoomNetworkServiceClass(rawValue: "responsive-data")
    public static let signaling = LoomNetworkServiceClass(rawValue: "signaling")
}
