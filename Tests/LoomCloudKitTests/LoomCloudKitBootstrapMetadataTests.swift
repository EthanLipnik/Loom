//
//  LoomCloudKitBootstrapMetadataTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import CloudKit
@testable import Loom
@testable import LoomCloudKit
import Foundation
import Testing

@Suite("Loom CloudKit Bootstrap Metadata")
struct LoomCloudKitBootstrapMetadataTests {
    @Test("CloudKit bootstrap metadata blob roundtrip")
    func cloudKitBootstrapMetadataBlobRoundtrip() throws {
        let metadata = LoomBootstrapMetadata(
            enabled: true,
            supportsControlChannel: false,
            supportsCredentialSubmission: true,
            endpoints: [LoomBootstrapEndpoint(host: "203.0.113.9", port: 2222, source: .user)],
            sshPort: 2222,
            controlPort: 9851,
            wakeOnLAN: nil
        )

        let record = CKRecord(recordType: "Peer", recordID: CKRecord.ID(recordName: UUID().uuidString))
        record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] = try JSONEncoder().encode(metadata)

        let blob = try #require(record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] as? Data)
        let decoded = try JSONDecoder().decode(LoomBootstrapMetadata.self, from: blob)
        #expect(decoded == metadata)
    }
}
