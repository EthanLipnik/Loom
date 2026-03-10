//
//  LoomGlobalSinkTestLock.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import Foundation

actor LoomGlobalSinkTestLock {
    static let shared = LoomGlobalSinkTestLock()

    func run<T>(
        reset: @escaping @Sendable () async -> Void = {},
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
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
