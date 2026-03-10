//
//  LoomTransferScheduler.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import Foundation

package actor LoomTransferScheduler {
    private struct TransferState: Sendable {
        var remainingBytes: UInt64
        var inFlightBytes: Int
        var credits: Int
    }

    private struct Waiter {
        let token: UUID
        let transferID: UUID
        let continuation: CheckedContinuation<Int, Never>
    }

    private let configuration: LoomTransferConfiguration
    private var transferStates: [UUID: TransferState] = [:]
    private var roundRobinOrder: [UUID] = []
    private var waiters: [Waiter] = []
    private var totalInFlightBytes = 0

    package init(configuration: LoomTransferConfiguration) {
        self.configuration = configuration
    }

    package func registerTransfer(
        id: UUID,
        remainingBytes: UInt64
    ) {
        if var existingState = transferStates[id] {
            existingState.remainingBytes = remainingBytes
            transferStates[id] = existingState
        } else {
            transferStates[id] = TransferState(
                remainingBytes: remainingBytes,
                inFlightBytes: 0,
                credits: initialCredits(for: remainingBytes)
            )
        }
        if roundRobinOrder.contains(id) == false {
            roundRobinOrder.append(id)
        }
        resumeEligibleWaiters()
    }

    package func acquireChunk(
        for id: UUID,
        remainingBytes: UInt64
    ) async -> Int {
        registerTransfer(id: id, remainingBytes: remainingBytes)
        let token = UUID()

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waiters.append(
                    Waiter(
                        token: token,
                        transferID: id,
                        continuation: continuation
                    )
                )
                resumeEligibleWaiters()
            }
        }, onCancel: {
            Task {
                await self.cancelWaiter(token: token)
            }
        })
    }

    package func releaseChunk(
        for id: UUID,
        bytes: Int,
        remainingBytes: UInt64
    ) {
        guard var state = transferStates[id] else {
            return
        }
        state.inFlightBytes = max(0, state.inFlightBytes - max(0, bytes))
        state.remainingBytes = remainingBytes
        transferStates[id] = state
        totalInFlightBytes = max(0, totalInFlightBytes - max(0, bytes))
        resumeEligibleWaiters()
    }

    package func finishTransfer(id: UUID) {
        guard let state = transferStates.removeValue(forKey: id) else {
            cancelWaiters(for: id)
            return
        }
        totalInFlightBytes = max(0, totalInFlightBytes - state.inFlightBytes)
        roundRobinOrder.removeAll { $0 == id }
        cancelWaiters(for: id)
        resumeEligibleWaiters()
    }

    private func cancelWaiter(token: UUID) {
        guard let waiterIndex = waiters.firstIndex(where: { $0.token == token }) else {
            return
        }
        let waiter = waiters.remove(at: waiterIndex)
        waiter.continuation.resume(returning: 0)
    }

    private func cancelWaiters(for id: UUID) {
        let cancelledWaiters = waiters.enumerated()
            .filter { $0.element.transferID == id }
            .map(\.offset)
            .reversed()

        for waiterIndex in cancelledWaiters {
            let waiter = waiters.remove(at: waiterIndex)
            waiter.continuation.resume(returning: 0)
        }
    }

    private func resumeEligibleWaiters() {
        while totalInFlightBytes < configuration.globalWindowBytes {
            pruneWaitersForFinishedTransfers()
            guard let selectedTransferID = nextEligibleTransferID(),
                  let waiterIndex = waiters.firstIndex(where: { $0.transferID == selectedTransferID }),
                  let grant = nextGrantSize(for: selectedTransferID),
                  grant > 0,
                  var state = transferStates[selectedTransferID] else {
                return
            }

            state.inFlightBytes += grant
            state.credits = max(0, state.credits - 1)
            transferStates[selectedTransferID] = state
            totalInFlightBytes += grant
            if state.credits == 0 {
                rotateTransferToBack(selectedTransferID)
            }

            let waiter = waiters.remove(at: waiterIndex)
            waiter.continuation.resume(returning: grant)
        }
    }

    private func pruneWaitersForFinishedTransfers() {
        let abandonedWaiters = waiters.enumerated()
            .filter { transferStates[$0.element.transferID] == nil }
            .map(\.offset)
            .reversed()

        for waiterIndex in abandonedWaiters {
            let waiter = waiters.remove(at: waiterIndex)
            waiter.continuation.resume(returning: 0)
        }
    }

    private func nextEligibleTransferID() -> UUID? {
        let waitingTransferIDs = Set(waiters.map(\.transferID))
        let orderedWaitingTransfers = roundRobinOrder.filter { waitingTransferIDs.contains($0) }
        guard orderedWaitingTransfers.isEmpty == false else {
            return nil
        }

        resetCreditsIfNeeded(for: orderedWaitingTransfers)

        for transferID in orderedWaitingTransfers {
            guard let state = transferStates[transferID],
                  state.credits > 0,
                  nextGrantSize(for: transferID) != nil else {
                continue
            }
            return transferID
        }

        return nil
    }

    private func nextGrantSize(for id: UUID) -> Int? {
        guard let state = transferStates[id] else {
            return nil
        }

        let globalAvailable = configuration.globalWindowBytes - totalInFlightBytes
        let transferAvailable = configuration.perTransferWindowBytes - state.inFlightBytes
        guard globalAvailable > 0,
              transferAvailable > 0,
              state.remainingBytes > 0 else {
            return nil
        }

        let remainingInt = Int(min(state.remainingBytes, UInt64(Int.max)))
        let grant = min(
            configuration.chunkSize,
            globalAvailable,
            transferAvailable,
            remainingInt
        )
        return grant > 0 ? grant : nil
    }

    private func resetCreditsIfNeeded(for orderedWaitingTransfers: [UUID]) {
        let hasRemainingCredits = orderedWaitingTransfers.contains { transferID in
            (transferStates[transferID]?.credits ?? 0) > 0
        }
        guard hasRemainingCredits == false else {
            return
        }

        for transferID in orderedWaitingTransfers {
            guard var state = transferStates[transferID] else {
                continue
            }
            state.credits = initialCredits(for: state.remainingBytes)
            transferStates[transferID] = state
        }
    }

    private func initialCredits(for remainingBytes: UInt64) -> Int {
        remainingBytes <= UInt64(configuration.smallObjectThresholdBytes) ? 2 : 1
    }

    private func rotateTransferToBack(_ id: UUID) {
        guard let index = roundRobinOrder.firstIndex(of: id) else {
            return
        }
        roundRobinOrder.remove(at: index)
        roundRobinOrder.append(id)
    }
}
