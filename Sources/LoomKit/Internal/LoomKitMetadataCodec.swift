//
//  LoomKitMetadataCodec.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

import Foundation
import Loom

enum LoomKitMetadataCodec {
    static let bootstrapMetadataKey = "loomkit.bootstrap.metadata"

    static func addingBootstrapMetadata(
        _ bootstrapMetadata: LoomBootstrapMetadata?,
        to metadata: [String: String]
    ) throws -> [String: String] {
        var metadata = metadata
        if let bootstrapMetadata {
            let encoded = try JSONEncoder().encode(bootstrapMetadata)
            metadata[bootstrapMetadataKey] = encoded.base64EncodedString()
        } else {
            metadata.removeValue(forKey: bootstrapMetadataKey)
        }
        return metadata
    }

    static func bootstrapMetadata(from advertisement: LoomPeerAdvertisement) -> LoomBootstrapMetadata? {
        guard let encoded = advertisement.metadata[bootstrapMetadataKey],
              let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return try? JSONDecoder().decode(LoomBootstrapMetadata.self, from: data)
    }
}
