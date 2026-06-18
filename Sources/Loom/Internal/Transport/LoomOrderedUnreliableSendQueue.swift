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
    package struct Limits: Sendable, Equatable {
        let maxOutstandingPackets: Int
        let maxOutstandingBytes: Int
        let maxQueuedPackets: Int?
        let replacesQueuedSends: Bool
        let maxDrainBurstPackets: Int?
        let drainBurstIntervalSeconds: TimeInterval
    }

    private struct PendingSend {
        let data: Data
        let options: LoomQueuedUnreliableSendOptions
        let enqueuedAt: TimeInterval
        let onComplete: @Sendable (Error?) -> Void
    }

    private enum ProtectedRealtimeFrameGroupKey: Hashable {
        case frame(UInt64)
        case unframed(Int)
    }

    private struct ProtectedRealtimeFrameGroup {
        let key: ProtectedRealtimeFrameGroupKey
        let indices: [Array<PendingSend>.Index]
        let packetCount: Int
        let queuedBytes: Int
        let declaredFragmentCount: Int
        let observedFragmentSlots: Int
        let maxFragmentBytes: Int

        var earliestIndex: Array<PendingSend>.Index {
            indices.first ?? 0
        }

        var latestIndex: Array<PendingSend>.Index {
            indices.last ?? earliestIndex
        }

        var estimatedPacketCount: Int {
            max(packetCount, declaredFragmentCount)
        }

        var estimatedBytes: Int {
            max(queuedBytes, maxFragmentBytes * estimatedPacketCount)
        }

        var isWholeFrameGroup: Bool {
            observedFragmentSlots >= declaredFragmentCount
        }
    }

    private struct ProtectedRealtimeFrameGroupAccumulator {
        var indices: [Array<PendingSend>.Index] = []
        var queuedBytes = 0
        var declaredFragmentCount = 1
        var observedFragmentIndexes: Set<Int> = []
        var unindexedFragmentCount = 0
        var maxFragmentBytes = 0

        mutating func append(
            _ pendingSend: PendingSend,
            index: Array<PendingSend>.Index
        ) {
            indices.append(index)
            queuedBytes += pendingSend.data.count
            declaredFragmentCount = max(
                declaredFragmentCount,
                max(1, pendingSend.options.fragmentCount ?? 1)
            )
            if let fragmentIndex = pendingSend.options.fragmentIndex {
                observedFragmentIndexes.insert(fragmentIndex)
            } else {
                unindexedFragmentCount += 1
            }
            maxFragmentBytes = max(maxFragmentBytes, pendingSend.data.count)
        }

        func group(key: ProtectedRealtimeFrameGroupKey) -> ProtectedRealtimeFrameGroup {
            ProtectedRealtimeFrameGroup(
                key: key,
                indices: indices,
                packetCount: indices.count,
                queuedBytes: queuedBytes,
                declaredFragmentCount: declaredFragmentCount,
                observedFragmentSlots: observedFragmentIndexes.count + unindexedFragmentCount,
                maxFragmentBytes: maxFragmentBytes
            )
        }
    }

    package static let defaultMaxOutstandingPackets = 1024
    package static let defaultMaxOutstandingBytes = 2 * 1024 * 1024
    package static let throughputProbeMaxOutstandingPackets = 262_144
    package static let throughputProbeMaxOutstandingBytes = 512 * 1024 * 1024

    private let queue: DispatchQueue
    private let sendOperation: @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
    private let maxOutstandingPackets: Int
    private let maxOutstandingBytes: Int
    private let maxQueuedPackets: Int?
    private let replacesQueuedSends: Bool
    private let maxDrainBurstPackets: Int?
    private let drainBurstIntervalSeconds: TimeInterval
    private let diagnosticsLabel: String
    private let profile: LoomQueuedUnreliableSendProfile?
    private var isClosed = false
    private var pendingSends: [PendingSend] = []
    private var outstandingPackets = 0
    private var outstandingBytes = 0
    private var diagnosticEnqueuedCount: UInt64 = 0
    private var diagnosticSentCount: UInt64 = 0
    private var diagnosticCompletedCount: UInt64 = 0
    private var diagnosticDroppedCount: UInt64 = 0
    private var diagnosticDeadlineDropCount: UInt64 = 0
    private var diagnosticQueueLimitDropCount: UInt64 = 0
    private var diagnosticSupersededDropCount: UInt64 = 0
    private var diagnosticErrorCount: UInt64 = 0
    private var diagnosticPendingMax = 0
    private var diagnosticOutstandingMax = 0
    private var diagnosticQueuedBytesMax = 0
    private var diagnosticQueueDwellSamplesMs: [Double] = []
    private var diagnosticContentProcessedSamplesMs: [Double] = []
    private var diagnosticSendGapSamplesMs: [Double] = []
    private var diagnosticLastSendStartedAt: TimeInterval = 0
    private var diagnosticLastLogAt: TimeInterval = 0
    private var expirySweepGeneration: UInt64 = 0
    private var burstDrainGeneration: UInt64 = 0
    private var deadlinePacingDrainGeneration: UInt64 = 0
    private var currentDrainBurstPackets = 0
    private var lastBurstSendStartedAt: TimeInterval = 0
    private var nextBurstDrainAllowedAt: TimeInterval = 0
    private var deadlinePacingNextAllowedAtByFrameID: [UInt64: TimeInterval] = [:]

    package static func limits(for profile: LoomQueuedUnreliableSendProfile) -> Limits {
        let recommendedLimits = profile.recommendedLimits
        let burstPolicy = drainBurstPolicy(for: profile)
        return Limits(
            maxOutstandingPackets: recommendedLimits.maxOutstandingPackets,
            maxOutstandingBytes: recommendedLimits.maxOutstandingBytes,
            maxQueuedPackets: recommendedLimits.maxQueuedPackets,
            replacesQueuedSends: profile == .priorityInputRealtime,
            maxDrainBurstPackets: burstPolicy.maxPackets,
            drainBurstIntervalSeconds: burstPolicy.intervalSeconds
        )
    }

    private static func resolvedDrainBurstPolicy(
        profile: LoomQueuedUnreliableSendProfile?,
        maxDrainBurstPackets: Int?,
        drainBurstIntervalSeconds: TimeInterval?
    ) -> (maxPackets: Int?, intervalSeconds: TimeInterval) {
        let defaultPolicy = drainBurstPolicy(for: profile)
        return (
            maxPackets: (maxDrainBurstPackets ?? defaultPolicy.maxPackets).map { max(1, $0) },
            intervalSeconds: max(0, drainBurstIntervalSeconds ?? defaultPolicy.intervalSeconds)
        )
    }

    private static func drainBurstPolicy(
        for profile: LoomQueuedUnreliableSendProfile?
    ) -> (maxPackets: Int?, intervalSeconds: TimeInterval) {
        switch profile {
        case .proximityRealtimeDisplay,
             .proximityRealtimeDisplaySingleLane:
            return (maxPackets: 4, intervalSeconds: 0.001)
        case .interactiveMedia,
             .proximityInteractiveMedia:
            return (maxPackets: 32, intervalSeconds: 0.001)
        case .interactiveAudio,
             .proximityInteractiveAudio:
            return (maxPackets: 8, intervalSeconds: 0.001)
        case .priorityInputRealtime,
             .priorityInputRealtimeSequenced,
             .priorityInputContinuous,
             .priorityInputProtected,
             .throughputProbe,
             .none:
            return (maxPackets: nil, intervalSeconds: 0)
        }
    }

    package init(
        connection: NWConnection,
        queue: DispatchQueue,
        maxOutstandingPackets: Int = defaultMaxOutstandingPackets,
        maxOutstandingBytes: Int = defaultMaxOutstandingBytes,
        maxQueuedPackets: Int? = nil,
        replacesQueuedSends: Bool = false,
        maxDrainBurstPackets: Int? = nil,
        drainBurstIntervalSeconds: TimeInterval? = nil,
        profile: LoomQueuedUnreliableSendProfile? = nil,
        diagnosticsLabel: String = "unlabeled"
    ) {
        let burstPolicy = Self.resolvedDrainBurstPolicy(
            profile: profile,
            maxDrainBurstPackets: maxDrainBurstPackets,
            drainBurstIntervalSeconds: drainBurstIntervalSeconds
        )
        self.queue = queue
        self.maxOutstandingPackets = max(1, maxOutstandingPackets)
        self.maxOutstandingBytes = max(1, maxOutstandingBytes)
        self.maxQueuedPackets = maxQueuedPackets.map { max(0, $0) }
        self.replacesQueuedSends = replacesQueuedSends
        self.maxDrainBurstPackets = burstPolicy.maxPackets
        self.drainBurstIntervalSeconds = burstPolicy.intervalSeconds
        self.profile = profile
        self.diagnosticsLabel = diagnosticsLabel
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
        maxQueuedPackets: Int? = nil,
        replacesQueuedSends: Bool = false,
        maxDrainBurstPackets: Int? = nil,
        drainBurstIntervalSeconds: TimeInterval? = nil,
        profile: LoomQueuedUnreliableSendProfile? = nil,
        diagnosticsLabel: String = "unlabeled",
        sendOperation: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
    ) {
        let burstPolicy = Self.resolvedDrainBurstPolicy(
            profile: profile,
            maxDrainBurstPackets: maxDrainBurstPackets,
            drainBurstIntervalSeconds: drainBurstIntervalSeconds
        )
        self.queue = queue
        self.maxOutstandingPackets = max(1, maxOutstandingPackets)
        self.maxOutstandingBytes = max(1, maxOutstandingBytes)
        self.maxQueuedPackets = maxQueuedPackets.map { max(0, $0) }
        self.replacesQueuedSends = replacesQueuedSends
        self.maxDrainBurstPackets = burstPolicy.maxPackets
        self.drainBurstIntervalSeconds = burstPolicy.intervalSeconds
        self.profile = profile
        self.diagnosticsLabel = diagnosticsLabel
        self.sendOperation = sendOperation
    }

    package func enqueue(
        _ data: Data,
        options: LoomQueuedUnreliableSendOptions = .none,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            guard !isClosed else {
                onComplete(makeDrop(reason: .closed, options: options))
                return
            }
            guard !isExpired(options, now: now) else {
                recordDrop(reason: .deadlineExpired)
                onComplete(makeDrop(reason: .deadlineExpired, options: options))
                return
            }
            if replacesQueuedSends {
                let droppedSends = pendingSends
                pendingSends.removeAll(keepingCapacity: true)
                droppedSends.forEach { drop($0, reason: .superseded) }
            }
            pendingSends.append(PendingSend(
                data: data,
                options: options,
                enqueuedAt: now,
                onComplete: onComplete
            ))
            diagnosticEnqueuedCount &+= 1
            updateDiagnosticMaxima()
            trimQueuedSendsIfNeeded(now: now)
            drainIfPossible()
            scheduleExpirySweepIfNeeded(now: ProcessInfo.processInfo.systemUptime)
            logDiagnosticsIfNeeded(now: now)
        }
    }

    package func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            let droppedSends = pendingSends
            pendingSends.removeAll(keepingCapacity: false)
            droppedSends.forEach { drop($0, reason: .closed) }
        }
    }

    private func trimQueuedSendsIfNeeded(now: TimeInterval) {
        guard let maxQueuedPackets else { return }
        while pendingSends.count > maxQueuedPackets {
            if let dropIndex = pendingSends.firstIndex(where: { isExpired($0.options, now: now) }) {
                dropPendingSend(at: dropIndex, reason: .deadlineExpired)
                continue
            }
            if let dropIndex = queueFullDropIndex() {
                dropPendingSend(at: dropIndex, reason: .queueLimit)
                continue
            }
            guard let protectedGroup = protectedRealtimeFrameGroupForQueueLimitDrop(
                maxQueuedPackets: maxQueuedPackets
            ) else {
                break
            }
            dropProtectedRealtimeFrameGroup(protectedGroup, reason: .queueLimit)
        }
        updateDiagnosticMaxima()
    }

    private func drainIfPossible() {
        while !pendingSends.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            dropExpiredPendingSends(now: now)
            guard !pendingSends.isEmpty else { return }
            if let delay = drainBurstDelay(now: now) {
                scheduleBurstDrain(after: delay)
                return
            }
            let nextSendIndex = nextSendIndex()
            let nextSend = pendingSends[nextSendIndex]
            if let delay = deadlinePacingDelay(for: nextSend, now: now) {
                scheduleDeadlinePacingDrain(after: delay)
                return
            }
            let nextBytes = nextSend.data.count
            let packetBudgetExceeded = outstandingPackets >= maxOutstandingPackets
            let byteBudgetExceeded = outstandingPackets > 0 &&
                (outstandingBytes + nextBytes) > maxOutstandingBytes

            if packetBudgetExceeded || byteBudgetExceeded {
                scheduleExpirySweepIfNeeded(now: now)
                return
            }

            pendingSends.remove(at: nextSendIndex)
            outstandingPackets += 1
            outstandingBytes += nextBytes
            let sendStartedAt = ProcessInfo.processInfo.systemUptime
            diagnosticSentCount &+= 1
            if diagnosticLastSendStartedAt > 0 {
                recordDiagnosticSample(
                    &diagnosticSendGapSamplesMs,
                    max(0, sendStartedAt - diagnosticLastSendStartedAt) * 1000
                )
            }
            diagnosticLastSendStartedAt = sendStartedAt
            recordBurstShapedSend(startedAt: sendStartedAt)
            recordDeadlinePacedSend(for: nextSend.options, startedAt: sendStartedAt)
            recordDiagnosticSample(
                &diagnosticQueueDwellSamplesMs,
                max(0, sendStartedAt - nextSend.enqueuedAt) * 1000
            )
            updateDiagnosticMaxima()

            sendOperation(nextSend.data) { [weak self] error in
                guard let self else {
                    nextSend.onComplete(LoomQueuedUnreliableSendDrop(
                        reason: .closed,
                        frameID: nextSend.options.frameID,
                        fragmentIndex: nextSend.options.fragmentIndex,
                        fragmentCount: nextSend.options.fragmentCount
                    ))
                    return
                }
                self.queue.async {
                    let completedAt = ProcessInfo.processInfo.systemUptime
                    self.outstandingPackets = max(0, self.outstandingPackets - 1)
                    self.outstandingBytes = max(0, self.outstandingBytes - nextBytes)
                    self.diagnosticCompletedCount &+= 1
                    if error != nil {
                        self.diagnosticErrorCount &+= 1
                    }
                    self.recordDiagnosticSample(
                        &self.diagnosticContentProcessedSamplesMs,
                        max(0, completedAt - sendStartedAt) * 1000
                    )
                    self.updateDiagnosticMaxima()
                    nextSend.onComplete(error)
                    self.drainIfPossible()
                    self.scheduleExpirySweepIfNeeded(now: completedAt)
                    self.logDiagnosticsIfNeeded(now: completedAt)
                }
            }
        }
    }

    private func drainBurstDelay(now: TimeInterval) -> TimeInterval? {
        guard let maxDrainBurstPackets,
              maxDrainBurstPackets > 0,
              drainBurstIntervalSeconds > 0 else {
            return nil
        }

        if lastBurstSendStartedAt > 0,
           now - lastBurstSendStartedAt >= drainBurstIntervalSeconds {
            currentDrainBurstPackets = 0
            nextBurstDrainAllowedAt = 0
        }
        if now < nextBurstDrainAllowedAt {
            return nextBurstDrainAllowedAt - now
        }
        guard currentDrainBurstPackets >= maxDrainBurstPackets else {
            return nil
        }

        nextBurstDrainAllowedAt = max(now, lastBurstSendStartedAt) + drainBurstIntervalSeconds
        if now >= nextBurstDrainAllowedAt {
            currentDrainBurstPackets = 0
            nextBurstDrainAllowedAt = 0
            return nil
        }
        return nextBurstDrainAllowedAt - now
    }

    private func recordBurstShapedSend(startedAt: TimeInterval) {
        guard maxDrainBurstPackets != nil,
              drainBurstIntervalSeconds > 0 else {
            return
        }
        if lastBurstSendStartedAt > 0,
           startedAt - lastBurstSendStartedAt >= drainBurstIntervalSeconds {
            currentDrainBurstPackets = 0
        }
        currentDrainBurstPackets += 1
        lastBurstSendStartedAt = startedAt
        if let maxDrainBurstPackets,
           currentDrainBurstPackets >= maxDrainBurstPackets {
            nextBurstDrainAllowedAt = startedAt + drainBurstIntervalSeconds
        }
    }

    private func deadlinePacingDelay(for pendingSend: PendingSend, now: TimeInterval) -> TimeInterval? {
        guard profile?.usesRealtimeDisplaySendPolicy == true,
              pendingSend.options.importance.usesRealtimeDeadlinePacing,
              let frameID = pendingSend.options.frameID else {
            return nil
        }
        guard let nextAllowedAt = deadlinePacingNextAllowedAtByFrameID[frameID] else {
            return nil
        }
        if now >= nextAllowedAt {
            deadlinePacingNextAllowedAtByFrameID[frameID] = nil
            return nil
        }
        return nextAllowedAt - now
    }

    private func recordDeadlinePacedSend(
        for options: LoomQueuedUnreliableSendOptions,
        startedAt: TimeInterval
    ) {
        guard profile?.usesRealtimeDisplaySendPolicy == true,
              options.importance.usesRealtimeDeadlinePacing,
              let frameID = options.frameID,
              let deadline = options.deadlineUptime,
              deadline > startedAt,
              let fragmentCount = options.fragmentCount,
              fragmentCount > 1 else {
            return
        }
        let fragmentIndex = options.fragmentIndex ?? 0
        let remainingFragments = max(0, fragmentCount - fragmentIndex - 1)
        guard remainingFragments > 0 else {
            deadlinePacingNextAllowedAtByFrameID[frameID] = nil
            return
        }
        let remainingSlack = deadline - startedAt
        let targetGap = remainingSlack / Double(remainingFragments)
        let minimumUsefulGap = max(0.0005, drainBurstIntervalSeconds * 1.25)
        guard targetGap >= minimumUsefulGap else {
            deadlinePacingNextAllowedAtByFrameID[frameID] = nil
            return
        }
        let maximumGap: TimeInterval = 0.008
        deadlinePacingNextAllowedAtByFrameID[frameID] = startedAt + min(maximumGap, targetGap)
        if deadlinePacingNextAllowedAtByFrameID.count > 256 {
            deadlinePacingNextAllowedAtByFrameID = deadlinePacingNextAllowedAtByFrameID.filter { _, nextAllowedAt in
                nextAllowedAt > startedAt
            }
        }
    }

    private func scheduleBurstDrain(after delay: TimeInterval) {
        burstDrainGeneration &+= 1
        let generation = burstDrainGeneration
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            self?.runBurstDrain(generation: generation)
        }
    }

    private func runBurstDrain(generation: UInt64) {
        guard generation == burstDrainGeneration else { return }
        currentDrainBurstPackets = 0
        nextBurstDrainAllowedAt = 0
        drainIfPossible()
        scheduleExpirySweepIfNeeded(now: ProcessInfo.processInfo.systemUptime)
    }

    private func scheduleDeadlinePacingDrain(after delay: TimeInterval) {
        deadlinePacingDrainGeneration &+= 1
        let generation = deadlinePacingDrainGeneration
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            self?.runDeadlinePacingDrain(generation: generation)
        }
    }

    private func runDeadlinePacingDrain(generation: UInt64) {
        guard generation == deadlinePacingDrainGeneration else { return }
        drainIfPossible()
        scheduleExpirySweepIfNeeded(now: ProcessInfo.processInfo.systemUptime)
    }

    private func nextSendIndex() -> Array<PendingSend>.Index {
        pendingSends.indices.max { lhs, rhs in
            pendingSends[lhs].options.importance.sendPriority <
                pendingSends[rhs].options.importance.sendPriority
        } ?? pendingSends.startIndex
    }

    private func queueFullDropIndex() -> Array<PendingSend>.Index? {
        pendingSends.indices
            .filter { pendingSends[$0].options.dropsWhenQueueFull }
            .min { lhs, rhs in
                pendingSends[lhs].options.importance.queueFullDropPriority <
                    pendingSends[rhs].options.importance.queueFullDropPriority
            }
    }

    private func dropPendingSend(
        at index: Array<PendingSend>.Index,
        reason: LoomQueuedUnreliableSendDrop.Reason
    ) {
        let droppedSend = pendingSends.remove(at: index)
        drop(droppedSend, reason: reason)
        dropSiblingRealtimeFrameFragmentsIfNeeded(for: droppedSend, reason: reason)
    }

    private func protectedRealtimeFrameGroupForQueueLimitDrop(
        maxQueuedPackets: Int
    ) -> ProtectedRealtimeFrameGroup? {
        let groups = protectedRealtimeFrameGroups()
        guard !groups.isEmpty else { return nil }
        guard profile?.usesRealtimeDisplaySendPolicy == true else {
            let protectedLimit = max(maxQueuedPackets, maxQueuedPackets + 4_096)
            return pendingSends.count > protectedLimit ? groups.first : nil
        }

        let packetSafetyCap = protectedRealtimeFrameGroupPacketSafetyCap(maxQueuedPackets: maxQueuedPackets)
        let byteSafetyCap = protectedRealtimeFrameGroupByteSafetyCap(maxQueuedPackets: maxQueuedPackets)
        let newestWholeAdmissibleGroup = groups
            .filter { group in
                group.isWholeFrameGroup &&
                    protectedRealtimeFrameGroupIsWithinSafetyCap(
                        group,
                        packetSafetyCap: packetSafetyCap,
                        byteSafetyCap: byteSafetyCap
                    )
            }
            .max(by: protectedRealtimeFrameGroupIsOlder)

        if let keeper = newestWholeAdmissibleGroup,
           let supersededGroup = groups
            .filter({ $0.key != keeper.key && $0.latestIndex < keeper.latestIndex })
            .min(by: protectedRealtimeFrameGroupIsOlder) {
            return supersededGroup
        }

        let protectedQueuedPackets = groups.reduce(0) { total, group in
            total + group.packetCount
        }
        let protectedQueuedBytes = groups.reduce(0) { total, group in
            total + group.queuedBytes
        }
        let exceedsAbsoluteSafetyCap =
            protectedQueuedPackets > packetSafetyCap ||
            protectedQueuedBytes > byteSafetyCap
        let hasOversizedGroup = groups.contains {
            !protectedRealtimeFrameGroupIsWithinSafetyCap(
                $0,
                packetSafetyCap: packetSafetyCap,
                byteSafetyCap: byteSafetyCap
            )
        }
        guard exceedsAbsoluteSafetyCap || hasOversizedGroup else {
            return nil
        }

        let fallbackKeeper = newestWholeAdmissibleGroup ?? groups
            .filter {
                protectedRealtimeFrameGroupIsWithinSafetyCap(
                    $0,
                    packetSafetyCap: packetSafetyCap,
                    byteSafetyCap: byteSafetyCap
                )
            }
            .max(by: protectedRealtimeFrameGroupIsOlder)
        let candidates = groups.filter { group in
            if let fallbackKeeper {
                group.key != fallbackKeeper.key
            } else {
                true
            }
        }
        if let oversizedGroup = candidates
            .filter({
                !protectedRealtimeFrameGroupIsWithinSafetyCap(
                    $0,
                    packetSafetyCap: packetSafetyCap,
                    byteSafetyCap: byteSafetyCap
                )
            })
            .min(by: protectedRealtimeFrameGroupIsOlder) {
            return oversizedGroup
        }
        if let incompleteGroup = candidates
            .filter({ !$0.isWholeFrameGroup })
            .min(by: protectedRealtimeFrameGroupIsOlder) {
            return incompleteGroup
        }
        return candidates.min(by: protectedRealtimeFrameGroupIsOlder)
    }

    private func protectedRealtimeFrameGroupPacketSafetyCap(maxQueuedPackets: Int) -> Int {
        guard profile?.usesRealtimeDisplaySendPolicy == true else {
            return max(maxQueuedPackets, maxQueuedPackets + 4_096)
        }
        return max(512, maxQueuedPackets * 32)
    }

    private func protectedRealtimeFrameGroupByteSafetyCap(maxQueuedPackets: Int) -> Int {
        guard profile?.usesRealtimeDisplaySendPolicy == true else {
            return Int.max
        }
        return max(maxOutstandingBytes * 32, maxQueuedPackets * 64 * 1024)
    }

    private func protectedRealtimeFrameGroups() -> [ProtectedRealtimeFrameGroup] {
        var accumulators: [ProtectedRealtimeFrameGroupKey: ProtectedRealtimeFrameGroupAccumulator] = [:]
        for index in pendingSends.indices {
            let pendingSend = pendingSends[index]
            guard let key = protectedRealtimeFrameGroupKey(for: pendingSend, index: index) else {
                continue
            }
            var accumulator = accumulators[key] ?? ProtectedRealtimeFrameGroupAccumulator()
            accumulator.append(pendingSend, index: index)
            accumulators[key] = accumulator
        }
        return accumulators.map { key, accumulator in
            accumulator.group(key: key)
        }
        .sorted(by: protectedRealtimeFrameGroupIsOlder)
    }

    private func protectedRealtimeFrameGroupKey(
        for pendingSend: PendingSend,
        index: Array<PendingSend>.Index
    ) -> ProtectedRealtimeFrameGroupKey? {
        guard pendingSend.options.importance.isProtectedRealtimeFrameData else {
            return nil
        }
        if let frameID = pendingSend.options.frameID {
            return .frame(frameID)
        }
        return .unframed(index)
    }

    private func protectedRealtimeFrameGroupIsWithinSafetyCap(
        _ group: ProtectedRealtimeFrameGroup,
        packetSafetyCap: Int,
        byteSafetyCap: Int
    ) -> Bool {
        group.estimatedPacketCount <= packetSafetyCap &&
            group.estimatedBytes <= byteSafetyCap
    }

    private func protectedRealtimeFrameGroupIsOlder(
        _ lhs: ProtectedRealtimeFrameGroup,
        _ rhs: ProtectedRealtimeFrameGroup
    ) -> Bool {
        if lhs.latestIndex != rhs.latestIndex {
            return lhs.latestIndex < rhs.latestIndex
        }
        return lhs.earliestIndex < rhs.earliestIndex
    }

    private func dropExpiredPendingSends(now: TimeInterval) {
        var index = pendingSends.startIndex
        while index < pendingSends.endIndex {
            let pendingSend = pendingSends[index]
            if isExpired(pendingSend.options, now: now) {
                pendingSends.remove(at: index)
                drop(pendingSend, reason: .deadlineExpired)
                dropSiblingRealtimeFrameFragmentsIfNeeded(for: pendingSend, reason: .deadlineExpired)
            } else {
                index = pendingSends.index(after: index)
            }
        }
    }

    private func dropSiblingRealtimeFrameFragmentsIfNeeded(
        for pendingSend: PendingSend,
        reason: LoomQueuedUnreliableSendDrop.Reason
    ) {
        guard pendingSend.options.importance.isRealtimeFrameData,
              let frameID = pendingSend.options.frameID else {
            return
        }

        var index = pendingSends.startIndex
        while index < pendingSends.endIndex {
            let candidate = pendingSends[index]
            guard candidate.options.frameID == frameID,
                  candidate.options.importance.dropsWithRealtimeFrameDataSibling else {
                index = pendingSends.index(after: index)
                continue
            }
            pendingSends.remove(at: index)
            drop(candidate, reason: reason)
        }
    }

    private func dropProtectedRealtimeFrameGroup(
        _ group: ProtectedRealtimeFrameGroup,
        reason: LoomQueuedUnreliableSendDrop.Reason
    ) {
        switch group.key {
        case .frame(let frameID):
            dropRealtimeFrameFragments(frameID: frameID, reason: reason)
        case .unframed:
            for index in group.indices.reversed() where index < pendingSends.endIndex {
                let droppedSend = pendingSends.remove(at: index)
                drop(droppedSend, reason: reason)
            }
        }
    }

    private func dropRealtimeFrameFragments(
        frameID: UInt64,
        reason: LoomQueuedUnreliableSendDrop.Reason
    ) {
        var index = pendingSends.startIndex
        while index < pendingSends.endIndex {
            let candidate = pendingSends[index]
            guard candidate.options.frameID == frameID,
                  candidate.options.importance.dropsWithRealtimeFrameDataSibling else {
                index = pendingSends.index(after: index)
                continue
            }
            pendingSends.remove(at: index)
            drop(candidate, reason: reason)
        }
    }

    private func scheduleExpirySweepIfNeeded(now: TimeInterval) {
        guard let nextDeadline = pendingSends.compactMap({ pendingSend -> TimeInterval? in
            guard pendingSend.options.dropsWhenExpired,
                  let deadline = pendingSend.options.deadlineUptime,
                  deadline > now else {
                return nil
            }
            return deadline
        }).min() else {
            expirySweepGeneration &+= 1
            return
        }

        expirySweepGeneration &+= 1
        let generation = expirySweepGeneration
        let delay = max(0, nextDeadline - now)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runExpirySweep(generation: generation)
        }
    }

    private func runExpirySweep(generation: UInt64) {
        guard generation == expirySweepGeneration else { return }
        let now = ProcessInfo.processInfo.systemUptime
        dropExpiredPendingSends(now: now)
        drainIfPossible()
        scheduleExpirySweepIfNeeded(now: ProcessInfo.processInfo.systemUptime)
        logDiagnosticsIfNeeded(now: now)
    }

    private func isExpired(_ options: LoomQueuedUnreliableSendOptions, now: TimeInterval) -> Bool {
        guard options.dropsWhenExpired, let deadline = options.deadlineUptime else {
            return false
        }
        return now >= deadline
    }

    private func drop(
        _ pendingSend: PendingSend,
        reason: LoomQueuedUnreliableSendDrop.Reason
    ) {
        recordDrop(reason: reason)
        pendingSend.onComplete(makeDrop(reason: reason, options: pendingSend.options))
    }

    private func recordDrop(reason: LoomQueuedUnreliableSendDrop.Reason) {
        diagnosticDroppedCount &+= 1
        switch reason {
        case .deadlineExpired:
            diagnosticDeadlineDropCount &+= 1
        case .queueLimit:
            diagnosticQueueLimitDropCount &+= 1
        case .superseded:
            diagnosticSupersededDropCount &+= 1
        case .unsupportedTransport:
            break
        case .closed:
            break
        }
    }

    private func makeDrop(
        reason: LoomQueuedUnreliableSendDrop.Reason,
        options: LoomQueuedUnreliableSendOptions
    ) -> LoomQueuedUnreliableSendDrop {
        LoomQueuedUnreliableSendDrop(
            reason: reason,
            profile: profile,
            frameID: options.frameID,
            fragmentIndex: options.fragmentIndex,
            fragmentCount: options.fragmentCount
        )
    }

    package func queuedBytesSnapshot() -> Int {
        queue.sync {
            pendingSends.reduce(into: outstandingBytes) { total, pendingSend in
                total += pendingSend.data.count
            }
        }
    }

    package func consumeDiagnosticsSnapshot() -> LoomQueuedUnreliableSendDiagnostics {
        queue.sync {
            let snapshot = diagnosticsSnapshotLocked()
            resetDiagnosticCountersLocked(now: ProcessInfo.processInfo.systemUptime)
            return snapshot
        }
    }

    private func updateDiagnosticMaxima() {
        diagnosticPendingMax = max(diagnosticPendingMax, pendingSends.count)
        diagnosticOutstandingMax = max(diagnosticOutstandingMax, outstandingPackets)
        diagnosticQueuedBytesMax = max(diagnosticQueuedBytesMax, queuedBytesUnsafe())
    }

    private func recordDiagnosticSample(_ samples: inout [Double], _ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        samples.append(value)
        if samples.count > 256 {
            samples.removeFirst(samples.count - 256)
        }
    }

    private func logDiagnosticsIfNeeded(now: TimeInterval) {
        guard LoomLogger.isEnabled(.transport) else { return }
        if diagnosticLastLogAt == 0 {
            diagnosticLastLogAt = now
            return
        }
        guard now - diagnosticLastLogAt >= 1 else { return }
        guard diagnosticEnqueuedCount > 0 ||
            diagnosticSentCount > 0 ||
            diagnosticCompletedCount > 0 ||
            diagnosticDroppedCount > 0 ||
            diagnosticErrorCount > 0 else {
            diagnosticLastLogAt = now
            return
        }
        LoomLogger.transport(
            "Unreliable send queue diagnostics profile=\(diagnosticsLabel) " +
                "enqueued=\(diagnosticEnqueuedCount) sent=\(diagnosticSentCount) " +
                "completed=\(diagnosticCompletedCount) dropped=\(diagnosticDroppedCount) " +
                "deadlineDrops=\(diagnosticDeadlineDropCount) queueLimitDrops=\(diagnosticQueueLimitDropCount) " +
                "supersededDrops=\(diagnosticSupersededDropCount) errors=\(diagnosticErrorCount) " +
                "pendingMax=\(diagnosticPendingMax) " +
                "outstandingMax=\(diagnosticOutstandingMax) queuedBytesMax=\(diagnosticQueuedBytesMax) " +
                "queueDwellP99=\(formatMs(percentile(diagnosticQueueDwellSamplesMs, 0.99)))ms " +
                "sendGapP99=\(formatMs(percentile(diagnosticSendGapSamplesMs, 0.99)))ms " +
                "contentProcessedP99=\(formatMs(percentile(diagnosticContentProcessedSamplesMs, 0.99)))ms"
        )
        resetDiagnosticCountersLocked(now: now)
    }

    private func diagnosticsSnapshotLocked() -> LoomQueuedUnreliableSendDiagnostics {
        LoomQueuedUnreliableSendDiagnostics(
            profile: profile,
            pendingPackets: pendingSends.count,
            outstandingPackets: outstandingPackets,
            queuedBytes: queuedBytesUnsafe(),
            pendingPacketMax: diagnosticPendingMax,
            outstandingPacketMax: diagnosticOutstandingMax,
            queuedBytesMax: diagnosticQueuedBytesMax,
            enqueuedCount: diagnosticEnqueuedCount,
            sentCount: diagnosticSentCount,
            completedCount: diagnosticCompletedCount,
            droppedCount: diagnosticDroppedCount,
            deadlineDropCount: diagnosticDeadlineDropCount,
            queueLimitDropCount: diagnosticQueueLimitDropCount,
            supersededDropCount: diagnosticSupersededDropCount,
            errorCount: diagnosticErrorCount,
            queueDwellP50Ms: percentile(diagnosticQueueDwellSamplesMs, 0.50),
            queueDwellP95Ms: percentile(diagnosticQueueDwellSamplesMs, 0.95),
            queueDwellP99Ms: percentile(diagnosticQueueDwellSamplesMs, 0.99),
            sendGapP50Ms: percentile(diagnosticSendGapSamplesMs, 0.50),
            sendGapP95Ms: percentile(diagnosticSendGapSamplesMs, 0.95),
            sendGapP99Ms: percentile(diagnosticSendGapSamplesMs, 0.99),
            contentProcessedP50Ms: percentile(diagnosticContentProcessedSamplesMs, 0.50),
            contentProcessedP95Ms: percentile(diagnosticContentProcessedSamplesMs, 0.95),
            contentProcessedP99Ms: percentile(diagnosticContentProcessedSamplesMs, 0.99)
        )
    }

    private func resetDiagnosticCountersLocked(now: TimeInterval) {
        diagnosticEnqueuedCount = 0
        diagnosticSentCount = 0
        diagnosticCompletedCount = 0
        diagnosticDroppedCount = 0
        diagnosticDeadlineDropCount = 0
        diagnosticQueueLimitDropCount = 0
        diagnosticSupersededDropCount = 0
        diagnosticErrorCount = 0
        diagnosticPendingMax = pendingSends.count
        diagnosticOutstandingMax = outstandingPackets
        diagnosticQueuedBytesMax = queuedBytesUnsafe()
        diagnosticQueueDwellSamplesMs.removeAll(keepingCapacity: true)
        diagnosticContentProcessedSamplesMs.removeAll(keepingCapacity: true)
        diagnosticSendGapSamplesMs.removeAll(keepingCapacity: true)
        diagnosticLastLogAt = now
    }

    private func queuedBytesUnsafe() -> Int {
        pendingSends.reduce(into: outstandingBytes) { total, pendingSend in
            total += pendingSend.data.count
        }
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = Swift.max(0, Swift.min(1, percentile))
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        return sorted[Swift.min(Swift.max(0, index), sorted.count - 1)]
    }

    private func formatMs(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

package extension LoomQueuedUnreliableSendOptions.Importance {
    var sendPriority: Int {
        switch self {
        case .realtimeKeyframe,
             .realtimeRecovery:
            2
        case .normal,
             .realtimeInterFrame,
             .realtimeParity:
            1
        }
    }

    var queueFullDropPriority: Int {
        switch self {
        case .realtimeParity:
            0
        case .realtimeInterFrame:
            1
        case .normal:
            2
        case .realtimeKeyframe,
             .realtimeRecovery:
            3
        }
    }

    var isRealtimeFrameData: Bool {
        switch self {
        case .realtimeInterFrame,
             .realtimeKeyframe,
             .realtimeRecovery:
            true
        case .normal,
             .realtimeParity:
            false
        }
    }

    var isProtectedRealtimeFrameData: Bool {
        switch self {
        case .realtimeKeyframe,
             .realtimeRecovery:
            true
        case .normal,
             .realtimeInterFrame,
             .realtimeParity:
            false
        }
    }

    var dropsWithRealtimeFrameDataSibling: Bool {
        switch self {
        case .realtimeInterFrame,
             .realtimeKeyframe,
             .realtimeRecovery,
             .realtimeParity:
            true
        case .normal:
            false
        }
    }

    var usesRealtimeDeadlinePacing: Bool {
        switch self {
        case .realtimeInterFrame,
             .realtimeKeyframe,
             .realtimeRecovery,
             .realtimeParity:
            true
        case .normal:
            false
        }
    }
}
