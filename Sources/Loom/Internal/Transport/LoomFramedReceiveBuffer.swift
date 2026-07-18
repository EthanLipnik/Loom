//
//  LoomFramedReceiveBuffer.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Retained-capacity accounting for one framed stream receive in progress.
///
/// The buffer may contain several complete frames plus a partial trailing frame.
/// Consuming bytes replaces the `Data` value so a maximum-sized receive does not
/// permanently pin its backing allocation.
package final class LoomFramedReceiveBuffer: @unchecked Sendable {
    package static let maximumReadAheadBytes = 256 * 1024
    package static let maximumRetainedBytes = LoomMessageLimits.maxFrameBytes
        + MemoryLayout<UInt32>.size
        + maximumReadAheadBytes

    private var storage = Data()
    private let retainedCapacityBudget: LoomIncomingRetainedCapacityBudget
    private var retainedFrameCount = 0

    package init(
        retainedCapacityBudget: LoomIncomingRetainedCapacityBudget? = nil
    ) {
        self.retainedCapacityBudget = retainedCapacityBudget ?? LoomIncomingRetainedCapacityBudget(
            maximumBytes: Self.maximumRetainedBytes,
            maximumPayloadCount: Self.maximumRetainedBytes,
            maximumBatchCount: Self.maximumRetainedBytes
        )
    }

    deinit {
        discard()
    }

    package var count: Int {
        storage.count
    }

    package func append(_ chunk: Data) throws {
        guard !chunk.isEmpty else {
            throw LoomError.protocolError("Received an empty Loom frame chunk.")
        }
        guard chunk.count <= Self.maximumRetainedBytes - storage.count else {
            throw LoomError.protocolError(
                "Incoming Loom frame exceeds the framed transport receive-buffer limit."
            )
        }
        var candidate = storage
        candidate.append(chunk)
        let candidateFrameCount = Self.logicalFrameCount(in: candidate)
        let addedFrameCount = candidateFrameCount - retainedFrameCount
        guard retainedCapacityBudget.reserve(
            bytes: chunk.count,
            payloadCount: addedFrameCount,
            startsNewBatch: addedFrameCount > 0
        ) else {
            throw LoomError.protocolError(
                "Incoming Loom frame exceeds the aggregate retained-capacity budget."
            )
        }

        storage = candidate
        retainedFrameCount = candidateFrameCount
    }

    package func declaredPayloadLength() throws -> Int {
        guard storage.count >= MemoryLayout<UInt32>.size else {
            throw LoomError.protocolError("Incomplete Loom frame header.")
        }
        return Int(
            (UInt32(storage[0]) << 24) |
                (UInt32(storage[1]) << 16) |
                (UInt32(storage[2]) << 8) |
                UInt32(storage[3])
        )
    }

    package func consumeCompleteFrame(requiredBytes: Int) throws -> Data {
        guard requiredBytes >= MemoryLayout<UInt32>.size,
              storage.count >= requiredBytes else {
            throw LoomError.protocolError("Attempted to consume an incomplete Loom frame.")
        }

        let payload = Data(storage[MemoryLayout<UInt32>.size ..< requiredBytes])
        let surplus = Data(storage.dropFirst(requiredBytes))
        storage = surplus
        retainedCapacityBudget.release(
            bytes: requiredBytes,
            payloadCount: 1,
            batchCount: 1
        )
        retainedFrameCount -= 1
        return payload
    }

    package func discard() {
        guard !storage.isEmpty || retainedFrameCount > 0 else { return }
        releaseReservationAndResetStorage()
    }

    package var retainedStorageBytesForTesting: Int {
        storage.count
    }

    private func releaseReservationAndResetStorage() {
        let retainedBytes = storage.count
        let retainedFrameCount = retainedFrameCount

        // Assigning a fresh value releases the old allocation instead of retaining
        // a maximum-sized frame's backing capacity for the lifetime of the session.
        storage = Data()
        self.retainedFrameCount = 0

        guard retainedBytes > 0 || retainedFrameCount > 0 else { return }
        retainedCapacityBudget.release(
            bytes: retainedBytes,
            payloadCount: retainedFrameCount,
            batchCount: retainedFrameCount
        )
    }

    private static func logicalFrameCount(in data: Data) -> Int {
        var frameCount = 0
        var offset = data.startIndex
        while offset < data.endIndex {
            frameCount += 1
            let remainingBytes = data.distance(from: offset, to: data.endIndex)
            guard remainingBytes >= MemoryLayout<UInt32>.size else { break }
            let length = Int(
                (UInt32(data[offset]) << 24) |
                    (UInt32(data[data.index(offset, offsetBy: 1)]) << 16) |
                    (UInt32(data[data.index(offset, offsetBy: 2)]) << 8) |
                    UInt32(data[data.index(offset, offsetBy: 3)])
            )
            guard length <= LoomMessageLimits.maxFrameBytes else { break }
            let framedLength = MemoryLayout<UInt32>.size + length
            guard remainingBytes >= framedLength else { break }
            offset = data.index(offset, offsetBy: framedLength)
        }
        return frameCount
    }
}
