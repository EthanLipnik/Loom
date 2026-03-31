//
//  LoomOrderedUnreliableSendQueue.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/30/26.
//

import Dispatch
import Foundation
import Network

package final class LoomOrderedUnreliableSendQueue: @unchecked Sendable {
    private struct PendingSend {
        let data: Data
        let onComplete: @Sendable (NWError?) -> Void
    }

    package static let defaultMaxOutstandingPackets = 32
    package static let defaultMaxOutstandingBytes = 256 * 1024

    private let queue: DispatchQueue
    private let sendOperation: @Sendable (Data, @escaping @Sendable (NWError?) -> Void) -> Void
    private let maxOutstandingPackets: Int
    private let maxOutstandingBytes: Int
    private var isClosed = false
    private var pendingSends: [PendingSend] = []
    private var outstandingPackets = 0
    private var outstandingBytes = 0

    package init(
        connection: NWConnection,
        queue: DispatchQueue,
        maxOutstandingPackets: Int = defaultMaxOutstandingPackets,
        maxOutstandingBytes: Int = defaultMaxOutstandingBytes
    ) {
        self.queue = queue
        self.maxOutstandingPackets = max(1, maxOutstandingPackets)
        self.maxOutstandingBytes = max(1, maxOutstandingBytes)
        sendOperation = { [connection] data, onComplete in
            connection.send(content: data, completion: .contentProcessed { error in
                onComplete(error)
            })
        }
    }

    package init(
        queue: DispatchQueue,
        maxOutstandingPackets: Int = defaultMaxOutstandingPackets,
        maxOutstandingBytes: Int = defaultMaxOutstandingBytes,
        sendOperation: @escaping @Sendable (Data, @escaping @Sendable (NWError?) -> Void) -> Void
    ) {
        self.queue = queue
        self.maxOutstandingPackets = max(1, maxOutstandingPackets)
        self.maxOutstandingBytes = max(1, maxOutstandingBytes)
        self.sendOperation = sendOperation
    }

    package func enqueue(_ data: Data, onComplete: @escaping @Sendable (NWError?) -> Void) {
        queue.async { [self] in
            guard !isClosed else {
                onComplete(.posix(.ECANCELED))
                return
            }
            pendingSends.append(PendingSend(data: data, onComplete: onComplete))
            drainIfPossible()
        }
    }

    package func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            let droppedSends = pendingSends
            pendingSends.removeAll(keepingCapacity: false)
            droppedSends.forEach { $0.onComplete(.posix(.ECANCELED)) }
        }
    }

    private func drainIfPossible() {
        while !pendingSends.isEmpty {
            let nextSend = pendingSends[0]
            let nextBytes = nextSend.data.count
            let packetBudgetExceeded = outstandingPackets >= maxOutstandingPackets
            let byteBudgetExceeded = outstandingPackets > 0 &&
                (outstandingBytes + nextBytes) > maxOutstandingBytes

            if packetBudgetExceeded || byteBudgetExceeded {
                return
            }

            pendingSends.removeFirst()
            outstandingPackets += 1
            outstandingBytes += nextBytes

            sendOperation(nextSend.data) { [weak self] error in
                guard let self else {
                    nextSend.onComplete(.posix(.ECANCELED))
                    return
                }
                self.queue.async {
                    self.outstandingPackets = max(0, self.outstandingPackets - 1)
                    self.outstandingBytes = max(0, self.outstandingBytes - nextBytes)
                    nextSend.onComplete(error)
                    self.drainIfPossible()
                }
            }
        }
    }

    package func queuedBytesSnapshot() -> Int {
        queue.sync {
            pendingSends.reduce(into: outstandingBytes) { total, pendingSend in
                total += pendingSend.data.count
            }
        }
    }
}
