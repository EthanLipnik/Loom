//
//  LoomAudioCodec.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation

/// Wire codec used by Loom's internal media transport helpers.
package enum LoomAudioCodec: UInt8, Sendable, Codable {
    case aacLC = 1
    case pcm16LE = 2
}
