//
//  LoomDataTransferSource.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

import Foundation
import Loom

final class LoomDataTransferSource: LoomTransferSource, Sendable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    var byteLength: UInt64 {
        UInt64(data.count)
    }

    func read(offset: UInt64, maxLength: Int) async throws -> Data {
        guard offset < byteLength else {
            return Data()
        }
        let startIndex = Int(offset)
        let endIndex = min(data.count, startIndex + maxLength)
        return Data(data[startIndex ..< endIndex])
    }
}
