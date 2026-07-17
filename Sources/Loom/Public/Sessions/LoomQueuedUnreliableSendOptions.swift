//
//  LoomQueuedUnreliableSendOptions.swift
//  Loom
//
//  Created by Ethan Lipnik on 6/2/26.
//

import Foundation

/// One payload in an ordered queued-unreliable batch.
///
/// A batch preserves item order while crossing Loom's stream, authenticated
/// session, and transport admission boundaries once. Each item retains its own
/// scheduling metadata and completion so callers can correlate transport
/// acceptance or failure without imposing a product-specific frame model.
public struct LoomQueuedUnreliableBatchItem: Sendable {
    /// Payload submitted on the multiplexed stream.
    public let data: Data
    /// Scheduling metadata applied to this payload.
    public let options: LoomQueuedUnreliableSendOptions
    /// Completion invoked exactly once when the payload is accepted, rejected,
    /// or intentionally discarded by the queued-send path.
    public let onComplete: @Sendable (Error?) -> Void

    /// Creates one queued-unreliable batch item.
    public init(
        data: Data,
        options: LoomQueuedUnreliableSendOptions = .none,
        onComplete: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        self.data = data
        self.options = options
        self.onComplete = onComplete
    }
}

/// Per-payload scheduling metadata for queued unreliable sends.
///
/// These options keep Loom product-agnostic while allowing high-rate media
/// callers to identify packet importance, deadlines, and frame grouping. The
/// transport may use them to drop stale inter-frame media before it consumes
/// scarce proximity-link send budget.
public struct LoomQueuedUnreliableSendOptions: Sendable, Codable, Equatable {
    /// Relative importance of one queued unreliable payload.
    public enum Importance: String, Sendable, Codable, Equatable {
        /// Generic queued unreliable payload with no media-specific protection.
        case normal
        /// Inter-frame realtime media that can be discarded once it becomes stale.
        case realtimeInterFrame
        /// Keyframe realtime media that should be protected from ordinary stale-frame drops.
        case realtimeKeyframe
        /// Recovery realtime media that should be protected from ordinary stale-frame drops.
        case realtimeRecovery
        /// Parity or repair media that is useful only inside the same playout window as its frame.
        case realtimeParity
    }

    /// Monotonic `ProcessInfo.processInfo.systemUptime` deadline for this payload.
    public var deadlineUptime: TimeInterval?
    /// Importance used for drop ordering under backpressure.
    public var importance: Importance
    /// Optional caller-owned frame identifier for diagnostics.
    public var frameID: UInt64?
    /// Optional zero-based fragment index within the frame.
    public var fragmentIndex: Int?
    /// Optional total fragment count for the frame.
    public var fragmentCount: Int?
    /// Whether Loom may drop this payload after `deadlineUptime`.
    public var dropsWhenExpired: Bool
    /// Whether Loom should prefer this payload when trimming a full queue.
    public var dropsWhenQueueFull: Bool

    /// Creates queued unreliable send options.
    public init(
        deadlineUptime: TimeInterval? = nil,
        importance: Importance = .normal,
        frameID: UInt64? = nil,
        fragmentIndex: Int? = nil,
        fragmentCount: Int? = nil,
        dropsWhenExpired: Bool? = nil,
        dropsWhenQueueFull: Bool? = nil
    ) {
        self.deadlineUptime = deadlineUptime
        self.importance = importance
        self.frameID = frameID
        self.fragmentIndex = fragmentIndex.map { max(0, $0) }
        self.fragmentCount = fragmentCount.map { max(0, $0) }
        self.dropsWhenExpired = dropsWhenExpired ?? importance.defaultDropsWhenExpired
        self.dropsWhenQueueFull = dropsWhenQueueFull ?? importance.defaultDropsWhenQueueFull
    }

    /// Options for ordinary queued unreliable payloads.
    public static let none = LoomQueuedUnreliableSendOptions()
}

extension LoomQueuedUnreliableSendOptions.Importance {
    fileprivate var defaultDropsWhenExpired: Bool {
        switch self {
        case .normal, .realtimeInterFrame, .realtimeParity:
            true
        case .realtimeKeyframe, .realtimeRecovery:
            false
        }
    }

    fileprivate var defaultDropsWhenQueueFull: Bool {
        switch self {
        case .normal, .realtimeInterFrame, .realtimeParity:
            true
        case .realtimeKeyframe, .realtimeRecovery:
            false
        }
    }
}

/// Nonfatal completion error emitted when Loom intentionally discards a queued
/// unreliable payload before transport submission.
public struct LoomQueuedUnreliableSendDrop: Error, LocalizedError, Sendable, Equatable {
    /// Drop reason selected by the queued-send scheduler.
    public enum Reason: String, Sendable, Codable, Equatable {
        /// The payload exceeded its caller-provided realtime deadline.
        case deadlineExpired
        /// The profile queue exceeded its bounded backlog window.
        case queueLimit
        /// A newer payload replaced this payload in a coalescing queue.
        case superseded
        /// The selected transport cannot provide the requested queued-unreliable lane semantics.
        case unsupportedTransport
        /// The stream or transport closed before the payload was submitted.
        case closed
    }

    public let reason: Reason
    public let profile: LoomQueuedUnreliableSendProfile?
    public let frameID: UInt64?
    public let fragmentIndex: Int?
    public let fragmentCount: Int?

    public init(
        reason: Reason,
        profile: LoomQueuedUnreliableSendProfile? = nil,
        frameID: UInt64? = nil,
        fragmentIndex: Int? = nil,
        fragmentCount: Int? = nil
    ) {
        self.reason = reason
        self.profile = profile
        self.frameID = frameID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
    }

    public var errorDescription: String? {
        var components = ["Queued unreliable send dropped: \(reason.rawValue)"]
        if let profile {
            components.append("profile=\(profile.rawValue)")
        }
        if let frameID {
            components.append("frame=\(frameID)")
        }
        if let fragmentIndex, let fragmentCount {
            components.append("fragment=\(fragmentIndex)/\(fragmentCount)")
        }
        return components.joined(separator: " ")
    }
}

/// Authenticated-session preparation timings for queued-unreliable batches.
///
/// The phases distinguish time spent waiting to enter the session actor from
/// envelope encoding, authenticated sealing, and transport queue admission.
public struct LoomQueuedUnreliableBatchPhaseDiagnostics: Sendable, Codable, Equatable {
    public let batchCount: UInt64
    public let itemCount: UInt64
    public let sessionWaitP50Ms: Double
    public let sessionWaitP95Ms: Double
    public let sessionWaitP99Ms: Double
    public let envelopeEncodeP50Ms: Double
    public let envelopeEncodeP95Ms: Double
    public let envelopeEncodeP99Ms: Double
    public let sealP50Ms: Double
    public let sealP95Ms: Double
    public let sealP99Ms: Double
    public let transportAdmissionP50Ms: Double
    public let transportAdmissionP95Ms: Double
    public let transportAdmissionP99Ms: Double
    public let totalAdmissionP50Ms: Double
    public let totalAdmissionP95Ms: Double
    public let totalAdmissionP99Ms: Double

    public init(
        batchCount: UInt64 = 0,
        itemCount: UInt64 = 0,
        sessionWaitP50Ms: Double = 0,
        sessionWaitP95Ms: Double = 0,
        sessionWaitP99Ms: Double = 0,
        envelopeEncodeP50Ms: Double = 0,
        envelopeEncodeP95Ms: Double = 0,
        envelopeEncodeP99Ms: Double = 0,
        sealP50Ms: Double = 0,
        sealP95Ms: Double = 0,
        sealP99Ms: Double = 0,
        transportAdmissionP50Ms: Double = 0,
        transportAdmissionP95Ms: Double = 0,
        transportAdmissionP99Ms: Double = 0,
        totalAdmissionP50Ms: Double = 0,
        totalAdmissionP95Ms: Double = 0,
        totalAdmissionP99Ms: Double = 0
    ) {
        self.batchCount = batchCount
        self.itemCount = itemCount
        self.sessionWaitP50Ms = sessionWaitP50Ms
        self.sessionWaitP95Ms = sessionWaitP95Ms
        self.sessionWaitP99Ms = sessionWaitP99Ms
        self.envelopeEncodeP50Ms = envelopeEncodeP50Ms
        self.envelopeEncodeP95Ms = envelopeEncodeP95Ms
        self.envelopeEncodeP99Ms = envelopeEncodeP99Ms
        self.sealP50Ms = sealP50Ms
        self.sealP95Ms = sealP95Ms
        self.sealP99Ms = sealP99Ms
        self.transportAdmissionP50Ms = transportAdmissionP50Ms
        self.transportAdmissionP95Ms = transportAdmissionP95Ms
        self.transportAdmissionP99Ms = transportAdmissionP99Ms
        self.totalAdmissionP50Ms = totalAdmissionP50Ms
        self.totalAdmissionP95Ms = totalAdmissionP95Ms
        self.totalAdmissionP99Ms = totalAdmissionP99Ms
    }
}

/// Structured diagnostics sampled from one queued-unreliable send profile.
public struct LoomQueuedUnreliableSendDiagnostics: Sendable, Codable, Equatable {
    public let profile: LoomQueuedUnreliableSendProfile?
    public let pendingPackets: Int
    public let outstandingPackets: Int
    public let queuedBytes: Int
    public let pendingPacketMax: Int
    public let outstandingPacketMax: Int
    public let queuedBytesMax: Int
    public let enqueuedCount: UInt64
    public let sentCount: UInt64
    public let completedCount: UInt64
    public let droppedCount: UInt64
    public let deadlineDropCount: UInt64
    public let queueLimitDropCount: UInt64
    public let supersededDropCount: UInt64
    public let errorCount: UInt64
    public let queueDwellP50Ms: Double
    public let queueDwellP95Ms: Double
    public let queueDwellP99Ms: Double
    public let sendGapP50Ms: Double
    public let sendGapP95Ms: Double
    public let sendGapP99Ms: Double
    public let contentProcessedP50Ms: Double
    public let contentProcessedP95Ms: Double
    public let contentProcessedP99Ms: Double
    /// Batch preparation phases, when batch traffic crossed the authenticated session.
    public let batchPhases: LoomQueuedUnreliableBatchPhaseDiagnostics?

    public init(
        profile: LoomQueuedUnreliableSendProfile?,
        pendingPackets: Int = 0,
        outstandingPackets: Int = 0,
        queuedBytes: Int = 0,
        pendingPacketMax: Int = 0,
        outstandingPacketMax: Int = 0,
        queuedBytesMax: Int = 0,
        enqueuedCount: UInt64 = 0,
        sentCount: UInt64 = 0,
        completedCount: UInt64 = 0,
        droppedCount: UInt64 = 0,
        deadlineDropCount: UInt64 = 0,
        queueLimitDropCount: UInt64 = 0,
        supersededDropCount: UInt64 = 0,
        errorCount: UInt64 = 0,
        queueDwellP50Ms: Double = 0,
        queueDwellP95Ms: Double = 0,
        queueDwellP99Ms: Double = 0,
        sendGapP50Ms: Double = 0,
        sendGapP95Ms: Double = 0,
        sendGapP99Ms: Double = 0,
        contentProcessedP50Ms: Double = 0,
        contentProcessedP95Ms: Double = 0,
        contentProcessedP99Ms: Double = 0,
        batchPhases: LoomQueuedUnreliableBatchPhaseDiagnostics? = nil
    ) {
        self.profile = profile
        self.pendingPackets = pendingPackets
        self.outstandingPackets = outstandingPackets
        self.queuedBytes = queuedBytes
        self.pendingPacketMax = pendingPacketMax
        self.outstandingPacketMax = outstandingPacketMax
        self.queuedBytesMax = queuedBytesMax
        self.enqueuedCount = enqueuedCount
        self.sentCount = sentCount
        self.completedCount = completedCount
        self.droppedCount = droppedCount
        self.deadlineDropCount = deadlineDropCount
        self.queueLimitDropCount = queueLimitDropCount
        self.supersededDropCount = supersededDropCount
        self.errorCount = errorCount
        self.queueDwellP50Ms = queueDwellP50Ms
        self.queueDwellP95Ms = queueDwellP95Ms
        self.queueDwellP99Ms = queueDwellP99Ms
        self.sendGapP50Ms = sendGapP50Ms
        self.sendGapP95Ms = sendGapP95Ms
        self.sendGapP99Ms = sendGapP99Ms
        self.contentProcessedP50Ms = contentProcessedP50Ms
        self.contentProcessedP95Ms = contentProcessedP95Ms
        self.contentProcessedP99Ms = contentProcessedP99Ms
        self.batchPhases = batchPhases
    }

    public var hasActivity: Bool {
        pendingPackets > 0 ||
            outstandingPackets > 0 ||
            enqueuedCount > 0 ||
            sentCount > 0 ||
            completedCount > 0 ||
            droppedCount > 0 ||
            errorCount > 0 ||
            (batchPhases?.batchCount ?? 0) > 0
    }

    package func replacingBatchPhases(
        _ batchPhases: LoomQueuedUnreliableBatchPhaseDiagnostics?
    ) -> LoomQueuedUnreliableSendDiagnostics {
        LoomQueuedUnreliableSendDiagnostics(
            profile: profile,
            pendingPackets: pendingPackets,
            outstandingPackets: outstandingPackets,
            queuedBytes: queuedBytes,
            pendingPacketMax: pendingPacketMax,
            outstandingPacketMax: outstandingPacketMax,
            queuedBytesMax: queuedBytesMax,
            enqueuedCount: enqueuedCount,
            sentCount: sentCount,
            completedCount: completedCount,
            droppedCount: droppedCount,
            deadlineDropCount: deadlineDropCount,
            queueLimitDropCount: queueLimitDropCount,
            supersededDropCount: supersededDropCount,
            errorCount: errorCount,
            queueDwellP50Ms: queueDwellP50Ms,
            queueDwellP95Ms: queueDwellP95Ms,
            queueDwellP99Ms: queueDwellP99Ms,
            sendGapP50Ms: sendGapP50Ms,
            sendGapP95Ms: sendGapP95Ms,
            sendGapP99Ms: sendGapP99Ms,
            contentProcessedP50Ms: contentProcessedP50Ms,
            contentProcessedP95Ms: contentProcessedP95Ms,
            contentProcessedP99Ms: contentProcessedP99Ms,
            batchPhases: batchPhases
        )
    }
}
