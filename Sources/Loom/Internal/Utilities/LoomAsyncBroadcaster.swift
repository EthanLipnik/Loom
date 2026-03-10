//
//  LoomAsyncBroadcaster.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import Foundation

package final class LoomAsyncBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    package init() {}

    package func makeStream(
        initialValue: Element? = nil
    ) -> AsyncStream<Element> {
        AsyncStream(Element.self) { continuation in
            let token = UUID()

            lock.lock()
            continuations[token] = continuation
            lock.unlock()

            if let initialValue {
                continuation.yield(initialValue)
            }

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(for: token)
            }
        }
    }

    package func yield(_ value: Element) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(value)
        }
    }

    package func finish() {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.finish()
        }
    }

    private func removeContinuation(for token: UUID) {
        lock.lock()
        continuations.removeValue(forKey: token)
        lock.unlock()
    }
}
