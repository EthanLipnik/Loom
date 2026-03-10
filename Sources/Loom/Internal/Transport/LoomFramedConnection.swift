//
//  LoomFramedConnection.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Network

package actor LoomFramedConnection {
    private let connection: NWConnection
    private var receiveBuffer = Data()

    package init(connection: NWConnection) {
        self.connection = connection
    }

    package func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = LoomReadyContinuationBox(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.complete(.success(()))
                case let .failed(error):
                    completion.complete(.failure(LoomError.connectionFailed(error)))
                case .cancelled:
                    completion.complete(.failure(LoomError.connectionFailed(CancellationError())))
                default:
                    break
                }
            }
        }
    }

    package func sendFrame(_ data: Data) async throws {
        var frame = Data(capacity: 4 + data.count)
        let length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(data)
        try await send(frame)
    }

    package func readFrame(maxBytes: Int = 1_048_576) async throws -> Data {
        while receiveBuffer.count < 4 {
            try await appendChunk()
        }

        let length =
            (UInt32(receiveBuffer[0]) << 24) |
            (UInt32(receiveBuffer[1]) << 16) |
            (UInt32(receiveBuffer[2]) << 8) |
            UInt32(receiveBuffer[3])
        guard length <= UInt32(maxBytes) else {
            throw LoomError.protocolError("Received Loom frame larger than \(maxBytes) bytes.")
        }
        let requiredBytes = 4 + Int(length)
        while receiveBuffer.count < requiredBytes {
            try await appendChunk()
        }

        let payload = Data(receiveBuffer[4..<requiredBytes])
        receiveBuffer.removeSubrange(0..<requiredBytes)
        return payload
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LoomError.connectionFailed(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func appendChunk() async throws {
        let chunk = try await receiveChunk()
        if chunk.isEmpty {
            throw LoomError.connectionFailed(CancellationError())
        }
        receiveBuffer.append(chunk)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: LoomError.connectionFailed(error))
                    return
                }
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(throwing: LoomError.protocolError("No data received from connection."))
            }
        }
    }
}

private final class LoomReadyContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
