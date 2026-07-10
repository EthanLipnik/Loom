//
//  LoomFramedReceiveBuffer.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// Retained-capacity accounting for one framed stream receive in progress.
///
/// `LoomFramedConnection` requests exactly the missing bytes for one frame, so a
/// completed frame consumes the entire buffer. Resetting the `Data` value after
/// each frame prevents a maximum-sized frame from permanently pinning its capacity.
package final class LoomFramedReceiveBuffer: @unchecked Sendable {
    package static let maximumRetainedBytes = LoomMessageLimits.maxFrameBytes + MemoryLayout<UInt32>.size

    private var storage = Data()
    private let retainedCapacityBudget: LoomIncomingRetainedCapacityBudget
    private var retainedChunkCount = 0

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
        guard retainedCapacityBudget.reserve(
            bytes: chunk.count,
            payloadCount: 1,
            startsNewBatch: true
        ) else {
            throw LoomError.protocolError(
                "Incoming Loom frame exceeds the aggregate retained-capacity budget."
            )
        }

        storage.append(chunk)
        retainedChunkCount += 1
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
              storage.count == requiredBytes else {
            throw LoomError.protocolError("Attempted to consume an incomplete Loom frame.")
        }

        let payload = Data(storage[MemoryLayout<UInt32>.size ..< requiredBytes])
        releaseReservationAndResetStorage()
        return payload
    }

    package func discard() {
        guard !storage.isEmpty || retainedChunkCount > 0 else { return }
        releaseReservationAndResetStorage()
    }

    package var retainedStorageBytesForTesting: Int {
        storage.count
    }

    private func releaseReservationAndResetStorage() {
        let retainedBytes = storage.count
        let retainedChunkCount = retainedChunkCount

        // Assigning a fresh value releases the old allocation instead of retaining
        // a maximum-sized frame's backing capacity for the lifetime of the session.
        storage = Data()
        self.retainedChunkCount = 0

        guard retainedBytes > 0, retainedChunkCount > 0 else { return }
        retainedCapacityBudget.release(
            bytes: retainedBytes,
            payloadCount: retainedChunkCount,
            batchCount: retainedChunkCount
        )
    }
}
