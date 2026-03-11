//
//  LoomGlobalSinkTestLock.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import Foundation

actor LoomGlobalSinkTestLock {
    static let shared = LoomGlobalSinkTestLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func lock() async {
        if isLocked == false {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        guard let nextWaiter = waiters.first else {
            isLocked = false
            return
        }

        waiters.removeFirst()
        nextWaiter.resume()
    }

    func run<T>(
        reset: @escaping @Sendable () async -> Void = {},
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await lock()
        defer {
            unlock()
        }
        await reset()
        do {
            let result = try await operation()
            await reset()
            return result
        } catch {
            await reset()
            throw error
        }
    }

    func runOnMainActor<T: Sendable>(
        reset: @escaping @Sendable () async -> Void = {},
        _ operation: @MainActor @Sendable () async throws -> T
    ) async rethrows -> T {
        await lock()
        defer {
            unlock()
        }
        await reset()
        do {
            let result = try await operation()
            await reset()
            return result
        } catch {
            await reset()
            throw error
        }
    }
}
