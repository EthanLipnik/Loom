//
//  LoomProtectedIdentityFileTests.swift
//  LoomPlatformAdaptersTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking
@testable import LoomPlatformAdapters
import Testing

@Suite("Protected Identity File")
struct LoomProtectedIdentityFileTests {
    @Test("Versioned protected payload round-trips without exposing key bytes in the header")
    func roundTrip() throws {
        let protectedBytes = Data((0..<257).map { UInt8(truncatingIfNeeded: $0) })
        let encoded = try LoomProtectedIdentityFile.encode(protectedBytes: protectedBytes)

        #expect(try LoomProtectedIdentityFile.decode(encoded) == protectedBytes)
        #expect(encoded.prefix(8) == Data([0x4c, 0x4f, 0x4f, 0x4d, 0x49, 0x44, 0x00, 0x00]))
        #expect(encoded.suffix(protectedBytes.count) == protectedBytes)
    }

    @Test("Corrupt and unsupported identity files fail closed")
    func invalidFiles() throws {
        let protectedBytes = Data([1, 2, 3, 4])
        let encoded = try LoomProtectedIdentityFile.encode(protectedBytes: protectedBytes)

        #expect(throws: LoomIdentityKeyStorageError.self) {
            _ = try LoomProtectedIdentityFile.decode(Data(encoded.dropLast()))
        }

        var unsupported = encoded
        unsupported[8] = 0
        unsupported[9] = 2
        #expect(throws: LoomIdentityKeyStorageError.self) {
            _ = try LoomProtectedIdentityFile.decode(unsupported)
        }
    }
}
