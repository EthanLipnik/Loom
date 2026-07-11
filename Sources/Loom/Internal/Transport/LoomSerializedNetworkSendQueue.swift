//
//  LoomSerializedNetworkSendQueue.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking

/// Preserves the submission order of callback-based queued sends while the
/// backend's async `send` operation is suspended.
package final class LoomSerializedNetworkSendQueue: @unchecked Sendable {
    private struct PendingSend {
        let data: Data
        let completion: @Sendable (Error?) -> Void
    }

    private let connection: any LoomNetworkConnection
    private let lock = NSLock()
    private var pendingSends: [PendingSend] = []
    private var isDraining = false
    private var isClosed = false

    package init(connection: any LoomNetworkConnection) {
        self.connection = connection
    }

    package func enqueue(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let shouldStartDraining: Bool
        let rejected: Bool
        lock.lock()
        if isClosed {
            shouldStartDraining = false
            rejected = true
        } else {
            pendingSends.append(PendingSend(data: data, completion: completion))
            shouldStartDraining = !isDraining
            isDraining = true
            rejected = false
        }
        lock.unlock()

        guard !rejected else {
            completion(LoomNetworkError(code: .closed, detail: "Network send queue is closed."))
            return
        }
        guard shouldStartDraining else { return }
        Task { [weak self] in
            await self?.drain()
        }
    }

    package func close() {
        let pending: [PendingSend]
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        pending = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        lock.unlock()

        let error = LoomNetworkError(code: .closed, detail: "Network send queue is closed.")
        for send in pending {
            send.completion(error)
        }
    }

    private func drain() async {
        while let send = takeNext() {
            do {
                try await connection.send(send.data)
                send.completion(nil)
            } catch {
                send.completion(error)
                failRemaining(with: error)
                return
            }
        }
    }

    private func takeNext() -> PendingSend? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !pendingSends.isEmpty else {
            isDraining = false
            return nil
        }
        return pendingSends.removeFirst()
    }

    private func failRemaining(with error: Error) {
        let pending: [PendingSend]
        lock.lock()
        isClosed = true
        isDraining = false
        pending = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        lock.unlock()

        for send in pending {
            send.completion(error)
        }
    }
}
