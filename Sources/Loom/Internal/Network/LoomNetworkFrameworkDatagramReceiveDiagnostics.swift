//
//  LoomNetworkFrameworkDatagramReceiveDiagnostics.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/14/26.
//

#if canImport(Network)
import Foundation

package final class LoomNetworkFrameworkDatagramReceiveDiagnostics: @unchecked Sendable {
    package struct Snapshot: Sendable, Equatable {
        package var callbackCount: UInt64
        package var callbackGapP95Ms: Double
        package var callbackGapP99Ms: Double
        package var callbackGapMaxMs: Double
        package var rearmGapP95Ms: Double
        package var rearmGapP99Ms: Double
        package var rearmGapMaxMs: Double
        package var armToCallbackP95Ms: Double
        package var armToCallbackP99Ms: Double
        package var armToCallbackMaxMs: Double
        package var callbackToResumeP95Ms: Double
        package var callbackToResumeP99Ms: Double
        package var callbackToResumeMaxMs: Double
    }

    private struct Histogram {
        private static let upperBoundsMs: [Double] = [
            0.25, 0.5, 1, 2, 4, 8, 16.7, 33.3, 50, 80, 125, 250, 500, 1_000,
        ]

        private(set) var sampleCount: UInt64 = 0
        private(set) var maximumMs: Double = 0
        private var bucketCounts = Array(
            repeating: UInt64(0),
            count: Self.upperBoundsMs.count + 1
        )

        mutating func record(milliseconds: Double) {
            guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 1_000 else { return }
            sampleCount &+= 1
            maximumMs = max(maximumMs, milliseconds)
            let bucketIndex = Self.upperBoundsMs.firstIndex { milliseconds <= $0 } ?? Self.upperBoundsMs.count
            bucketCounts[bucketIndex] &+= 1
        }

        func percentile(_ percentile: Double) -> Double {
            guard sampleCount > 0 else { return 0 }
            let clampedPercentile = min(max(percentile, 0), 1)
            let target = max(UInt64(1), UInt64((Double(sampleCount) * clampedPercentile).rounded(.up)))
            var accumulated: UInt64 = 0
            for (index, count) in bucketCounts.enumerated() {
                accumulated &+= count
                guard accumulated >= target else { continue }
                if index < Self.upperBoundsMs.count {
                    return Self.upperBoundsMs[index]
                }
                return maximumMs
            }
            return maximumMs
        }

        mutating func reset() {
            sampleCount = 0
            maximumMs = 0
            for index in bucketCounts.indices {
                bucketCounts[index] = 0
            }
        }
    }

    private let lock = NSLock()
    private var callbackCount: UInt64 = 0
    private var lastCallbackAt: TimeInterval?
    private var currentRegistrationAt: TimeInterval?
    private var lastLogAt: TimeInterval?
    private var callbackGap = Histogram()
    private var rearmGap = Histogram()
    private var armToCallback = Histogram()
    private var callbackToResume = Histogram()

    package func recordRegistration(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        currentRegistrationAt = now
        if let lastCallbackAt {
            rearmGap.record(milliseconds: max(0, now - lastCallbackAt) * 1_000)
        }
        lock.unlock()
    }

    package func recordCallback(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        callbackCount &+= 1
        if let lastCallbackAt {
            callbackGap.record(milliseconds: max(0, now - lastCallbackAt) * 1_000)
        }
        if let currentRegistrationAt {
            armToCallback.record(milliseconds: max(0, now - currentRegistrationAt) * 1_000)
        }
        currentRegistrationAt = nil
        lastCallbackAt = now
        if lastLogAt == nil {
            lastLogAt = now
        }
        lock.unlock()
    }

    package func recordConsumerResume(
        afterCallbackAt callbackAt: TimeInterval,
        strategy: LoomNetworkFrameworkDatagramReceiveStrategy,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let snapshotToLog: Snapshot?
        lock.lock()
        callbackToResume.record(milliseconds: max(0, now - callbackAt) * 1_000)
        if let lastLogAt, now - lastLogAt >= 1, callbackCount > 0 {
            snapshotToLog = snapshotLocked()
            resetIntervalLocked(at: now)
        } else {
            snapshotToLog = nil
        }
        lock.unlock()

        guard let snapshotToLog else { return }
        LoomLogger.transport(
            "Datagram receive diagnostics strategy=\(strategy.rawValue) " +
                "callbacks=\(snapshotToLog.callbackCount) " +
                "callbackGapP95=\(formatMs(snapshotToLog.callbackGapP95Ms))ms " +
                "callbackGapP99=\(formatMs(snapshotToLog.callbackGapP99Ms))ms " +
                "callbackGapMax=\(formatMs(snapshotToLog.callbackGapMaxMs))ms " +
                "rearmGapP95=\(formatMs(snapshotToLog.rearmGapP95Ms))ms " +
                "rearmGapP99=\(formatMs(snapshotToLog.rearmGapP99Ms))ms " +
                "rearmGapMax=\(formatMs(snapshotToLog.rearmGapMaxMs))ms " +
                "armToCallbackP95=\(formatMs(snapshotToLog.armToCallbackP95Ms))ms " +
                "armToCallbackP99=\(formatMs(snapshotToLog.armToCallbackP99Ms))ms " +
                "armToCallbackMax=\(formatMs(snapshotToLog.armToCallbackMaxMs))ms " +
                "callbackToResumeP95=\(formatMs(snapshotToLog.callbackToResumeP95Ms))ms " +
                "callbackToResumeP99=\(formatMs(snapshotToLog.callbackToResumeP99Ms))ms " +
                "callbackToResumeMax=\(formatMs(snapshotToLog.callbackToResumeMaxMs))ms"
        )
    }

    package func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(
            callbackCount: callbackCount,
            callbackGapP95Ms: callbackGap.percentile(0.95),
            callbackGapP99Ms: callbackGap.percentile(0.99),
            callbackGapMaxMs: callbackGap.maximumMs,
            rearmGapP95Ms: rearmGap.percentile(0.95),
            rearmGapP99Ms: rearmGap.percentile(0.99),
            rearmGapMaxMs: rearmGap.maximumMs,
            armToCallbackP95Ms: armToCallback.percentile(0.95),
            armToCallbackP99Ms: armToCallback.percentile(0.99),
            armToCallbackMaxMs: armToCallback.maximumMs,
            callbackToResumeP95Ms: callbackToResume.percentile(0.95),
            callbackToResumeP99Ms: callbackToResume.percentile(0.99),
            callbackToResumeMaxMs: callbackToResume.maximumMs
        )
    }

    private func resetIntervalLocked(at now: TimeInterval) {
        callbackCount = 0
        callbackGap.reset()
        rearmGap.reset()
        armToCallback.reset()
        callbackToResume.reset()
        lastLogAt = now
    }

    private func formatMs(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

#endif
