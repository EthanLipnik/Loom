//
//  LoomAsyncBroadcaster.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

package final class LoomAsyncBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    package init(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) {
        self.bufferingPolicy = bufferingPolicy
    }

    package func makeStream(
        initialValue: Element? = nil
    ) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: bufferingPolicy
        )
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
        return stream
    }

    @discardableResult
    package func yield(_ value: Element) -> Bool {
        lock.lock()
        let activeContinuations = Array(continuations)
        lock.unlock()

        var didAcceptAllValues = true
        var terminatedTokens: [UUID] = []
        for (token, continuation) in activeContinuations {
            switch continuation.yield(value) {
            case .enqueued:
                break
            case .dropped:
                didAcceptAllValues = false
            case .terminated:
                terminatedTokens.append(token)
            @unknown default:
                didAcceptAllValues = false
            }
        }

        if !terminatedTokens.isEmpty {
            lock.lock()
            for token in terminatedTokens {
                continuations.removeValue(forKey: token)
            }
            lock.unlock()
        }
        return didAcceptAllValues
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
