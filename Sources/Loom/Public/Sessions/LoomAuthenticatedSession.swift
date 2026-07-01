//
//  LoomAuthenticatedSession.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Network

/// Lifecycle state for an authenticated Loom session.
public enum LoomAuthenticatedSessionState: Sendable, Equatable, Codable {
    case idle
    case handshaking
    case ready
    case cancelled
    case failed(String)
}

/// Negotiated session metadata produced by the Loom handshake.
public struct LoomAuthenticatedSessionContext: Sendable, Codable, Equatable {
    public let peerIdentity: LoomPeerIdentity
    public let peerAdvertisement: LoomPeerAdvertisement
    public let trustEvaluation: LoomTrustEvaluation
    public let transportKind: LoomTransportKind
    public let transportDiagnostics: LoomTransportDiagnostics
    public let negotiatedFeatures: [String]
    public let sessionEncrypted: Bool

    public init(
        peerIdentity: LoomPeerIdentity,
        peerAdvertisement: LoomPeerAdvertisement,
        trustEvaluation: LoomTrustEvaluation,
        transportKind: LoomTransportKind,
        transportDiagnostics: LoomTransportDiagnostics? = nil,
        negotiatedFeatures: [String],
        sessionEncrypted: Bool = true
    ) {
        self.peerIdentity = peerIdentity
        self.peerAdvertisement = peerAdvertisement
        self.trustEvaluation = trustEvaluation
        self.transportKind = transportKind
        self.transportDiagnostics = transportDiagnostics ?? LoomTransportDiagnostics(
            selectedTransportKind: transportKind,
            usableDatagramSize: nil,
            serviceClass: nil,
            receiveSemantics: "unknown"
        )
        self.negotiatedFeatures = negotiatedFeatures
        self.sessionEncrypted = sessionEncrypted
    }
}

/// Transport capability and selection diagnostics captured at authenticated-session setup.
public struct LoomTransportDiagnostics: Sendable, Codable, Equatable {
    public let selectedTransportKind: LoomTransportKind
    public let usableDatagramSize: Int?
    public let serviceClass: String?
    public let receiveSemantics: String

    public init(
        selectedTransportKind: LoomTransportKind,
        usableDatagramSize: Int?,
        serviceClass: String?,
        receiveSemantics: String
    ) {
        self.selectedTransportKind = selectedTransportKind
        self.usableDatagramSize = usableDatagramSize
        self.serviceClass = serviceClass
        self.receiveSemantics = receiveSemantics
    }
}

/// Queue profile for ordered unreliable sends on a multiplexed Loom stream.
///
/// Use ``interactiveMedia`` for latency-sensitive media where small transport
/// buffers help prevent stale packets from accumulating. Use
/// ``proximityRealtimeDisplay`` for deadline-paced display/video traffic on
/// bursty peer-to-peer proximity links with independent media receive lanes,
/// and ``proximityRealtimeDisplaySingleLane`` when the transport shares one
/// receive lane but still needs realtime display send-side pacing. Use
/// ``interactiveAudio`` and ``proximityInteractiveAudio`` for low-latency audio lanes. Use
/// ``priorityInputRealtime``, ``priorityInputRealtimeSequenced``,
/// ``priorityInputContinuous``, and ``priorityInputProtected`` for first-class
/// input lanes that must not sit behind media stream traffic. Use
/// ``throughputProbe`` when you need to intentionally overdrive a path and
/// observe where loss begins, such as an explicit network-capacity test.
public enum LoomQueuedUnreliableSendProfile: String, Sendable, Codable, CaseIterable {
    /// Keeps the underlying ordered unreliable queue shallow to favor latency.
    case interactiveMedia
    /// Bounds media backlog more aggressively for bursty proximity links such as AWDL.
    case proximityInteractiveMedia
    /// Keeps realtime display/video backlog below a short playout window on bursty proximity links.
    case proximityRealtimeDisplay
    /// Keeps realtime display/video pacing on single-lane proximity transports.
    case proximityRealtimeDisplaySingleLane
    /// Keeps the audio lane shallow without using the display/video queue.
    case interactiveAudio
    /// Keeps proximity audio backlog tighter than generic media on bursty proximity links.
    case proximityInteractiveAudio
    /// Keeps only the newest pending input payload when the transport is busy.
    case priorityInputRealtime
    /// Preserves a short FIFO window of realtime input while bounding stale backlog.
    case priorityInputRealtimeSequenced
    /// Preserves compact continuous-input batches without replacing queued packets.
    case priorityInputContinuous
    /// Preserves protected input ordering with a shallow independent queue.
    case priorityInputProtected
    /// Allows a much deeper queue so throughput probes can saturate fast paths.
    case throughputProbe

    /// Recommended queue limits for this profile.
    ///
    /// Products that keep their own enqueue budget in front of Loom should use
    /// these values so app-level pacing and Loom's internal queue depth stay in
    /// sync for the selected send profile.
    public var recommendedLimits: LoomQueuedUnreliableSendLimits {
        switch self {
        case .interactiveMedia:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 1024,
                maxOutstandingBytes: 2 * 1024 * 1024
            )
        case .proximityInteractiveMedia:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 384,
                maxOutstandingBytes: 768 * 1024,
                maxQueuedPackets: 128
            )
        case .proximityRealtimeDisplay,
             .proximityRealtimeDisplaySingleLane:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 96,
                maxOutstandingBytes: 192 * 1024,
                maxQueuedPackets: 32
            )
        case .interactiveAudio:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 256,
                maxOutstandingBytes: 256 * 1024,
                maxQueuedPackets: 96
            )
        case .proximityInteractiveAudio:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 128,
                maxOutstandingBytes: 128 * 1024,
                maxQueuedPackets: 48
            )
        case .priorityInputRealtime:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 1,
                maxOutstandingBytes: 64 * 1024
            )
        case .priorityInputRealtimeSequenced:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 8,
                maxOutstandingBytes: 128 * 1024,
                maxQueuedPackets: 8
            )
        case .priorityInputContinuous:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 64,
                maxOutstandingBytes: 512 * 1024
            )
        case .priorityInputProtected:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 64,
                maxOutstandingBytes: 256 * 1024
            )
        case .throughputProbe:
            LoomQueuedUnreliableSendLimits(
                maxOutstandingPackets: 262_144,
                maxOutstandingBytes: 512 * 1024 * 1024
            )
        }
    }

    package var requiresIndependentUnreliableLane: Bool {
        switch self {
        case .proximityRealtimeDisplay:
            true
        case .proximityRealtimeDisplaySingleLane,
             .interactiveMedia, .proximityInteractiveMedia, .interactiveAudio, .proximityInteractiveAudio,
             .priorityInputRealtime, .priorityInputRealtimeSequenced, .priorityInputContinuous,
             .priorityInputProtected, .throughputProbe:
            false
        }
    }

    package var usesRealtimeDisplaySendPolicy: Bool {
        switch self {
        case .proximityRealtimeDisplay,
             .proximityRealtimeDisplaySingleLane:
            true
        case .interactiveMedia,
             .proximityInteractiveMedia,
             .interactiveAudio,
             .proximityInteractiveAudio,
             .priorityInputRealtime,
             .priorityInputRealtimeSequenced,
             .priorityInputContinuous,
             .priorityInputProtected,
             .throughputProbe:
            false
        }
    }
}

/// Recommended queue window for a ``LoomQueuedUnreliableSendProfile``.
public struct LoomQueuedUnreliableSendLimits: Sendable, Equatable, Codable {
    public let maxOutstandingPackets: Int
    public let maxOutstandingBytes: Int
    public let maxQueuedPackets: Int?

    public init(
        maxOutstandingPackets: Int,
        maxOutstandingBytes: Int,
        maxQueuedPackets: Int? = nil
    ) {
        self.maxOutstandingPackets = maxOutstandingPackets
        self.maxOutstandingBytes = maxOutstandingBytes
        self.maxQueuedPackets = maxQueuedPackets
    }
}

/// A logical bidirectional stream multiplexed over an authenticated Loom session.
public final class LoomMultiplexedStream: @unchecked Sendable, Hashable {
    public let id: UInt16
    public let label: String?
    public let incomingBytes: AsyncStream<Data>

    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var incomingByteBatchDispatcher: LoomIncomingByteBatchDispatcher?
    private let sendHandler: @Sendable (Data) async throws -> Void
    private let unreliableSendHandler: @Sendable (Data) async throws -> Void
    private let queuedUnreliableSendHandler:
        @Sendable (
            Data,
            LoomQueuedUnreliableSendProfile,
            LoomQueuedUnreliableSendOptions,
            @escaping @Sendable (Error?) -> Void
        ) async -> Void
    private let queuedUnreliableResetHandler:
        @Sendable (LoomQueuedUnreliableSendProfile) async -> Void
    private let queuedUnreliableDiagnosticsHandler:
        @Sendable (LoomQueuedUnreliableSendProfile) async -> LoomQueuedUnreliableSendDiagnostics?
    private let closeHandler: @Sendable () async throws -> Void
    private let queuedUnreliableSubmitter = LoomOrderedAsyncSubmitter()
    private let realtimeDisplayQueuedUnreliableSubmitter = LoomOrderedAsyncSubmitter()
    private var didClose = false

    package init(
        id: UInt16,
        label: String?,
        sendHandler: @escaping @Sendable (Data) async throws -> Void,
        unreliableSendHandler: @escaping @Sendable (Data) async throws -> Void,
        queuedUnreliableSendHandler:
            @escaping @Sendable (
                Data,
                LoomQueuedUnreliableSendProfile,
                LoomQueuedUnreliableSendOptions,
                @escaping @Sendable (Error?) -> Void
            ) async -> Void,
        queuedUnreliableResetHandler:
            @escaping @Sendable (LoomQueuedUnreliableSendProfile) async -> Void,
        queuedUnreliableDiagnosticsHandler:
            @escaping @Sendable (LoomQueuedUnreliableSendProfile) async -> LoomQueuedUnreliableSendDiagnostics? = { _ in nil },
        closeHandler: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.label = label
        self.sendHandler = sendHandler
        self.unreliableSendHandler = unreliableSendHandler
        self.queuedUnreliableSendHandler = queuedUnreliableSendHandler
        self.queuedUnreliableResetHandler = queuedUnreliableResetHandler
        self.queuedUnreliableDiagnosticsHandler = queuedUnreliableDiagnosticsHandler
        self.closeHandler = closeHandler
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        incomingBytes = stream
        self.continuation = continuation
    }

    package convenience init(
        id: UInt16,
        label: String?,
        sendHandler: @escaping @Sendable (Data) async throws -> Void,
        unreliableSendHandler: @escaping @Sendable (Data) async throws -> Void,
        queuedUnreliableSendHandler:
            @escaping @Sendable (
                Data,
                LoomQueuedUnreliableSendProfile,
                LoomQueuedUnreliableSendOptions,
                @escaping @Sendable (Error?) -> Void
            ) async -> Void,
        queuedUnreliableResetHandler:
            @escaping @Sendable (LoomQueuedUnreliableSendProfile) async -> Void,
        closeHandler: @escaping @Sendable () async throws -> Void
    ) {
        self.init(
            id: id,
            label: label,
            sendHandler: sendHandler,
            unreliableSendHandler: unreliableSendHandler,
            queuedUnreliableSendHandler: queuedUnreliableSendHandler,
            queuedUnreliableResetHandler: queuedUnreliableResetHandler,
            queuedUnreliableDiagnosticsHandler: { _ in nil },
            closeHandler: closeHandler
        )
    }

    public func send(_ data: Data) async throws {
        try await sendHandler(data)
    }

    public func sendUnreliable(_ data: Data) async throws {
        try await unreliableSendHandler(data)
    }

    /// Queues an unreliable payload for ordered transmission without waiting for
    /// the underlying `NWConnection.send` completion before returning.
    ///
    /// Completion runs later on transport acceptance or failure.
    public func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile = .interactiveMedia,
        onComplete: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        sendUnreliableQueued(
            data,
            profile: profile,
            options: .none,
            onComplete: onComplete
        )
    }

    /// Queues an unreliable payload with caller-provided realtime scheduling metadata.
    ///
    /// Completion runs later on transport acceptance, transport failure, or an
    /// intentional nonfatal ``LoomQueuedUnreliableSendDrop``.
    public func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile = .interactiveMedia,
        options: LoomQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        let submitter = profile.usesRealtimeDisplaySendPolicy
            ? realtimeDisplayQueuedUnreliableSubmitter
            : queuedUnreliableSubmitter
        submitter.enqueue(
            operation: { [queuedUnreliableSendHandler, profile, options] markQueued in
                Task {
                    await queuedUnreliableSendHandler(data, profile, options, onComplete)
                    markQueued()
                }
            },
            deadlineUptime: options.deadlineUptime,
            dropsWhenExpired: options.dropsWhenExpired,
            maxPendingOperations: profile.recommendedLimits.maxQueuedPackets,
            dropsWhenQueueFull: options.dropsWhenQueueFull,
            queueFullDropPriority: options.importance.queueFullDropPriority,
            onExpired: {
                onComplete(
                    LoomQueuedUnreliableSendDrop(
                        reason: .deadlineExpired,
                        profile: profile,
                        frameID: options.frameID,
                        fragmentIndex: options.fragmentIndex,
                        fragmentCount: options.fragmentCount
                    )
                )
            },
            onQueueLimit: {
                onComplete(
                    LoomQueuedUnreliableSendDrop(
                        reason: .queueLimit,
                        profile: profile,
                        frameID: options.frameID,
                        fragmentIndex: options.fragmentIndex,
                        fragmentCount: options.fragmentCount
                    )
                )
            },
            onDropped: {
                onComplete(
                    LoomError.connectionFailed(
                        LoomConnectionFailure(reason: .cancelled, detail: "Unreliable send queue cancelled.")
                    )
                )
            }
        )
    }

    /// Cancels queued unreliable sends for one profile without closing the stream.
    ///
    /// This is intended for explicit throughput probes that want to discard
    /// stale queued traffic after crossing an overload boundary.
    public func resetQueuedUnreliableSends(
        profile: LoomQueuedUnreliableSendProfile
    ) async {
        await queuedUnreliableResetHandler(profile)
    }

    /// Consumes structured diagnostics for one queued-unreliable send profile.
    public func consumeQueuedUnreliableSendDiagnostics(
        profile: LoomQueuedUnreliableSendProfile
    ) async -> LoomQueuedUnreliableSendDiagnostics? {
        await queuedUnreliableDiagnosticsHandler(profile)
    }

    /// Installs an exclusive batched inbound payload handler for high-rate streams.
    ///
    /// When a batch handler is installed, newly received payloads are delivered
    /// to the handler instead of `incomingBytes`. This keeps existing stream
    /// consumers source-compatible while allowing media pipelines to avoid a
    /// per-payload `AsyncStream` resume on hot paths.
    public func setIncomingBytesBatchHandler(
        maxBatchSize: Int = 32,
        maxDelay: Duration = .milliseconds(1),
        handler: @escaping @Sendable ([Data]) async -> Void
    ) {
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: maxBatchSize,
            maxDelay: maxDelay,
            handler: handler
        )

        lock.lock()
        let previousDispatcher = incomingByteBatchDispatcher
        incomingByteBatchDispatcher = dispatcher
        lock.unlock()

        previousDispatcher?.finish()
    }

    /// Installs an exclusive synchronous inbound payload handler for hot media streams.
    ///
    /// Unlike `setIncomingBytesBatchHandler`, this handler runs on the receive
    /// delivery path and does not hop through an `AsyncStream` worker task. It
    /// flushes when `maxBatchSize` is reached or when the handler is cleared.
    /// Keep the handler lightweight and hand work off to a stream-owned queue.
    public func setIncomingBytesImmediateBatchHandler(
        maxBatchSize: Int = 32,
        handler: @escaping @Sendable ([Data]) -> Void
    ) {
        let dispatcher = LoomIncomingByteBatchDispatcher(
            maxBatchSize: maxBatchSize,
            immediateHandler: handler
        )

        lock.lock()
        let previousDispatcher = incomingByteBatchDispatcher
        incomingByteBatchDispatcher = dispatcher
        lock.unlock()

        previousDispatcher?.finish()
    }

    /// Removes any installed batched inbound payload handler.
    public func clearIncomingBytesBatchHandler() {
        lock.lock()
        let dispatcher = incomingByteBatchDispatcher
        incomingByteBatchDispatcher = nil
        lock.unlock()

        dispatcher?.finish()
    }

    public func close() async throws {
        guard markClosed() else {
            return
        }

        defer {
            finishQueuedOutbound()
            finishInbound()
        }
        try await closeHandler()
    }

    private func markClosed() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !didClose else {
            return false
        }
        didClose = true
        return true
    }

    public static func == (lhs: LoomMultiplexedStream, rhs: LoomMultiplexedStream) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    package func yield(_ data: Data) {
        lock.lock()
        let dispatcher = incomingByteBatchDispatcher
        let continuation = continuation
        lock.unlock()

        if let dispatcher {
            dispatcher.yield(data)
        } else {
            continuation?.yield(data)
        }
    }

    package func finishInbound() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let dispatcher = incomingByteBatchDispatcher
        incomingByteBatchDispatcher = nil
        lock.unlock()
        dispatcher?.finish()
        continuation?.finish()
    }

    package func finishQueuedOutbound() {
        queuedUnreliableSubmitter.close()
        realtimeDisplayQueuedUnreliableSubmitter.close()
    }
}

/// Trust status frame exchanged during the Loom handshake between
/// hello exchange and encryption setup.
///
/// The **receiver** (host) sends one or two of these frames:
/// - If trust resolves quickly: a single `.trusted` or `.denied` frame.
/// - If trust requires manual approval: a `.pendingApproval` frame first,
///   then `.trusted` or `.denied` once the user responds.
///
/// The **initiator** (client) reads these frames to know the trust state
/// without relying on timeout heuristics.
public enum LoomHandshakeTrustStatus: UInt8, Codable, Sendable {
    case pendingApproval = 0
    case trusted = 1
    case denied = 2
}

/// Authenticated Loom session that provides generic multiplexed streams.
public actor LoomAuthenticatedSession: LoomSessionProtocol {
    private enum EnvelopeReceiveLane {
        case reliable
        case unreliable
    }

    private struct PendingUnopenedUnreliableStreamData {
        var payloads: [Data]
        var totalBytes: Int
        var firstBufferedAt: CFAbsoluteTime
        var lastBufferedAt: CFAbsoluteTime
    }

    /// Stable authenticated-session identifier for app-owned bookkeeping.
    public nonisolated let id: UUID
    public let role: LoomSessionRole
    public let transportKind: LoomTransportKind

    public nonisolated let incomingStreams: AsyncStream<LoomMultiplexedStream>

    public private(set) var state: LoomAuthenticatedSessionState = .idle
    public private(set) var context: LoomAuthenticatedSessionContext?
    public private(set) var bootstrapProgress = LoomAuthenticatedSessionBootstrapProgress(phase: .idle)

    /// Called on the initiator (client) when the receiver (host) signals
    /// that trust evaluation is pending manual approval.
    public var onTrustPending: (@Sendable @MainActor () -> Void)?

    /// Called when authenticated-session bootstrap advances before the session becomes ready.
    public var onBootstrapProgress: (@Sendable (LoomAuthenticatedSessionBootstrapProgress) -> Void)?

    /// Sets the trust-pending callback from outside the actor.
    public func setOnTrustPending(_ handler: (@Sendable @MainActor () -> Void)?) {
        onTrustPending = handler
    }

    /// Sets the bootstrap-progress callback from outside the actor.
    public func setOnBootstrapProgress(
        _ handler: (@Sendable (LoomAuthenticatedSessionBootstrapProgress) -> Void)?
    ) {
        onBootstrapProgress = handler
    }

    private let connection: LoomConnection
    private let nwConnection: NWConnection?
    private let transport: any LoomSessionTransport
    private let incomingStreamContinuation: AsyncStream<LoomMultiplexedStream>.Continuation
    private let incomingStreamObservers = LoomAsyncBroadcaster<LoomMultiplexedStream>()
    private let stateObservers = LoomAsyncBroadcaster<LoomAuthenticatedSessionState>()
    private let bootstrapProgressObservers = LoomAsyncBroadcaster<LoomAuthenticatedSessionBootstrapProgress>()
    private let pathObservers = LoomAsyncBroadcaster<LoomSessionNetworkPathSnapshot>()
    private var streams: [UInt16: LoomMultiplexedStream] = [:]
    private var nextOutgoingStreamID: UInt16
    private var readTask: Task<Void, Never>?
    private var unreliableReadTask: Task<Void, Never>?
    private var securityContext: LoomSessionSecurityContext?
    private var encryptionEnabled = false
    private var currentRemoteEndpoint: NWEndpoint?
    private var currentPathSnapshot: LoomSessionNetworkPathSnapshot?
    private var transportObserversConfigured = false
    private var pendingUnopenedUnreliableDataByStreamID: [UInt16: PendingUnopenedUnreliableStreamData] = [:]
    private let pendingUnopenedUnreliableDataTTL: CFAbsoluteTime = 2.0
    private let pendingUnopenedUnreliableDataMaxStreams = 8
    private let pendingUnopenedUnreliableDataMaxPayloadsPerStream = 768
    private let pendingUnopenedUnreliableDataMaxBytesPerStream = 2 * 1024 * 1024
    private var recentlyClosedStreamIDs: [UInt16: CFAbsoluteTime] = [:]
    private let recentlyClosedStreamTTL: CFAbsoluteTime = 2.0
    private let recentlyClosedStreamMaxCount = 64
    private let transportEndpointDescription: String
    private let quicRemoteEndpoint: NWEndpoint?
    private let quicPathSnapshotProvider: (@Sendable () -> LoomSessionNetworkPathSnapshot?)?
    private let transportServiceClassDescription: String?
    private let transportUsableDatagramSize: Int?

    public init(
        connection: LoomConnection,
        role: LoomSessionRole,
        remoteEndpoint: NWEndpoint? = nil,
        serviceClass: NWParameters.ServiceClass? = nil
    ) {
        id = UUID()
        self.connection = connection
        self.role = role
        switch connection {
        case let .tcp(connection):
            nwConnection = connection
            transportKind = .tcp
            transport = LoomFramedConnection(connection: connection)
            transportEndpointDescription = (remoteEndpoint ?? connection.endpoint).debugDescription
            quicRemoteEndpoint = nil
            quicPathSnapshotProvider = nil
            transportServiceClassDescription = serviceClass.map(Self.serviceClassDescription(_:))
            transportUsableDatagramSize = nil
        case let .udp(connection):
            nwConnection = connection
            transportKind = .udp
            transport = LoomReliableChannel(connection: connection)
            transportEndpointDescription = (remoteEndpoint ?? connection.endpoint).debugDescription
            quicRemoteEndpoint = nil
            quicPathSnapshotProvider = nil
            transportServiceClassDescription = serviceClass.map(Self.serviceClassDescription(_:))
            transportUsableDatagramSize = Loom.defaultMaxPacketSize
        case let .quic(connection):
            nwConnection = nil
            transportKind = .quic
            transport = LoomQUICSessionTransport(
                connection: connection,
                role: role
            )
            transportEndpointDescription = (remoteEndpoint ?? connection.remoteEndpoint)?.debugDescription ?? "quic"
            quicRemoteEndpoint = remoteEndpoint ?? connection.remoteEndpoint
            quicPathSnapshotProvider = {
                connection.currentPath.map(LoomSessionNetworkPathSnapshot.init(path:))
            }
            transportServiceClassDescription = serviceClass.map(Self.serviceClassDescription(_:))
            transportUsableDatagramSize = LoomQUICTransportFactory.defaultMaxDatagramFrameSize
        }
        let (stream, continuation) = AsyncStream.makeStream(of: LoomMultiplexedStream.self)
        incomingStreams = stream
        incomingStreamContinuation = continuation
        nextOutgoingStreamID = role == .initiator ? 1 : 2
    }

    deinit {
        incomingStreamContinuation.finish()
        incomingStreamObservers.finish()
        stateObservers.finish()
        bootstrapProgressObservers.finish()
        pathObservers.finish()
        readTask?.cancel()
        unreliableReadTask?.cancel()
    }

    /// Creates an additional observation stream for incoming multiplexed streams.
    public nonisolated func makeIncomingStreamObserver() -> AsyncStream<LoomMultiplexedStream> {
        incomingStreamObservers.makeStream()
    }

    /// Creates an observation stream for lifecycle state transitions.
    public func makeStateObserver() -> AsyncStream<LoomAuthenticatedSessionState> {
        stateObservers.makeStream(initialValue: state)
    }

    /// Creates an observation stream for bootstrap progress before the session becomes ready.
    public func makeBootstrapProgressObserver() -> AsyncStream<LoomAuthenticatedSessionBootstrapProgress> {
        bootstrapProgressObservers.makeStream(initialValue: bootstrapProgress)
    }

    /// Returns the latest remote endpoint observed for this session's transport.
    public var remoteEndpoint: NWEndpoint? {
        currentRemoteEndpoint ?? currentPathSnapshot?.remoteEndpoint ?? nwConnection?.endpoint ?? quicRemoteEndpoint
    }

    /// Returns the latest transport-path snapshot observed for this session.
    public var pathSnapshot: LoomSessionNetworkPathSnapshot? {
        currentPathSnapshot
    }

    private func transportDiagnosticsSnapshot() -> LoomTransportDiagnostics {
        LoomTransportDiagnostics(
            selectedTransportKind: transportKind,
            usableDatagramSize: transportUsableDatagramSize,
            serviceClass: transportServiceClassDescription,
            receiveSemantics: Self.receiveSemanticsDescription(transport.receiveSemantics)
        )
    }

    private static func receiveSemanticsDescription(_ semantics: LoomSessionReceiveSemantics) -> String {
        switch semantics {
        case .singleLane:
            "single-lane"
        case .independentReliableAndUnreliable:
            "independent-reliable-unreliable"
        }
    }

    private static func serviceClassDescription(_ serviceClass: NWParameters.ServiceClass) -> String {
        switch serviceClass {
        case .bestEffort:
            "best-effort"
        case .background:
            "background"
        case .interactiveVideo:
            "interactive-video"
        case .interactiveVoice:
            "interactive-voice"
        case .responsiveData:
            "responsive-data"
        case .signaling:
            "signaling"
        @unknown default:
            String(describing: serviceClass)
        }
    }

    /// Creates an observation stream for transport-path changes on the underlying connection.
    public func makePathObserver() -> AsyncStream<LoomSessionNetworkPathSnapshot> {
        pathObservers.makeStream(initialValue: currentPathSnapshot)
    }

    public func start(
        localHello: LoomSessionHelloRequest,
        identityManager: LoomIdentityManager,
        trustProvider: (any LoomTrustProvider)? = nil,
        helloValidator: LoomSessionHelloValidator = LoomSessionHelloValidator(),
        encryptionPolicy: LoomSessionEncryptionPolicy = .required,
        expectedPeerIdentityKeyID: String? = nil,
        expectedPeerIdentityPublicKey: Data? = nil,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) async throws -> LoomAuthenticatedSessionContext {
        guard case .idle = state else {
            if let context {
                return context
            }
            throw LoomError.protocolError("Authenticated Loom session has already started.")
        }

        do {
            updateState(.handshaking)
            updateBootstrapProgress(phase: .transportStarting)
            let preparedHello = try await MainActor.run {
                try LoomSessionHelloValidator.makePreparedSignedHello(
                    from: localHello,
                    identityManager: identityManager
                )
            }
            let helloData = try JSONEncoder().encode(preparedHello.hello)
            try await transport.startAndAwaitReady(queue: queue)
            updateBootstrapProgress(phase: .transportReady)
            try await transport.sendHandshakeMessage(helloData)
            updateBootstrapProgress(phase: .localHelloSent)

            let remoteHello = try await receiveRemoteHello()
            let validatedHello = try await helloValidator.validateDetailed(
                remoteHello,
                endpointDescription: transportEndpointDescription
            )
            let peerIdentity = validatedHello.peerIdentity
            try Self.validateExpectedPeerIdentity(
                peerIdentity,
                expectedKeyID: expectedPeerIdentityKeyID,
                expectedPublicKey: expectedPeerIdentityPublicKey
            )
            updateBootstrapProgress(phase: .remoteHelloReceived)

            let negotiatedFeatures = Array(
                Set(localHello.supportedFeatures).intersection(remoteHello.supportedFeatures)
            )
            .sorted()

            let encryptionNegotiated = negotiatedFeatures.contains("loom.session-encryption.v1")
            switch encryptionPolicy {
            case .required:
                guard encryptionNegotiated else {
                    finishSession(
                        state: .failed("missing-session-encryption"),
                        cancelUnderlyingConnection: true
                    )
                    throw LoomError.protocolError("Peer does not support Loom authenticated session encryption.")
                }
            case .optional:
                break
            }

            let trustEvaluation: LoomTrustEvaluation
            if role == .receiver {
                trustEvaluation = try await resolveAndSignalTrust(
                    for: peerIdentity,
                    trustProvider: trustProvider
                )
            } else {
                trustEvaluation = try await receiveHostTrustStatus()
            }
            if trustEvaluation.decision != .trusted {
                finishSession(state: .failed("denied"), cancelUnderlyingConnection: true)
                throw LoomError.authenticationFailed
            }

            if encryptionNegotiated {
                securityContext = try LoomSessionSecurityContext(
                    role: role,
                    localHello: preparedHello.hello,
                    remoteHello: validatedHello.hello,
                    localEphemeralPrivateKey: preparedHello.ephemeralPrivateKey
                )
            }
            encryptionEnabled = encryptionNegotiated

            let context = LoomAuthenticatedSessionContext(
                peerIdentity: peerIdentity,
                peerAdvertisement: validatedHello.hello.advertisement,
                trustEvaluation: trustEvaluation,
                transportKind: transportKind,
                transportDiagnostics: transportDiagnosticsSnapshot(),
                negotiatedFeatures: negotiatedFeatures,
                sessionEncrypted: encryptionNegotiated
            )
            self.context = context
            configureTransportObserversIfNeeded()
            if transport.receiveSemantics == .independentReliableAndUnreliable {
                try await transport.prepareUnreliableReceive(maxBytes: LoomMessageLimits.maxFrameBytes)
            }
            updateBootstrapProgress(phase: .ready)
            updateState(.ready)
            readTask = Task { [weak self] in
                await self?.runReadLoop()
            }
            if transport.receiveSemantics == .independentReliableAndUnreliable {
                unreliableReadTask = Task { [weak self] in
                    await self?.runUnreliableReadLoop()
                }
            }
            return context
        } catch {
            updateBootstrapFailure(reason: error.localizedDescription)
            finishSession(
                state: .failed(error.localizedDescription),
                cancelUnderlyingConnection: true
            )
            throw error
        }
    }

    private func receiveRemoteHello() async throws -> LoomSessionHello {
        let remoteHelloData = try await transport.receiveHandshakeMessage(
            maxBytes: LoomMessageLimits.maxHelloFrameBytes
        )
        do {
            return try JSONDecoder().decode(LoomSessionHello.self, from: remoteHelloData)
        } catch {
            guard transportKind == .udp else {
                throw LoomError.decodingError(error)
            }
            throw LoomError.connectionFailed(
                LoomConnectionFailure(
                    reason: .transportLoss,
                    detail: "Received malformed Loom session hello over UDP: \(error.localizedDescription)"
                )
            )
        }
    }

    private static func validateExpectedPeerIdentity(
        _ peerIdentity: LoomPeerIdentity,
        expectedKeyID: String?,
        expectedPublicKey: Data?
    ) throws {
        if let expectedKeyID,
           peerIdentity.identityKeyID != expectedKeyID {
            throw LoomError.authenticationFailed
        }
        if let expectedPublicKey,
           peerIdentity.identityPublicKey != expectedPublicKey {
            throw LoomError.authenticationFailed
        }
    }

    public func openStream(label: String? = nil) async throws -> LoomMultiplexedStream {
        guard case .ready = state else {
            throw LoomError.protocolError("Authenticated Loom session is not ready.")
        }
        if let label {
            let labelLength = label.lengthOfBytes(using: .utf8)
            guard labelLength <= LoomMessageLimits.maxStreamLabelBytes else {
                throw LoomError.protocolError(
                    "Authenticated Loom stream labels must not exceed \(LoomMessageLimits.maxStreamLabelBytes) UTF-8 bytes."
                )
            }
        }
        let streamID = nextOutgoingStreamID
        guard streamID != 0 else {
            throw LoomError.protocolError("Authenticated Loom session exhausted available stream identifiers.")
        }
        let maxStreamID: UInt16 = role == .initiator ? .max : (.max - 1)
        if streamID == maxStreamID {
            nextOutgoingStreamID = 0
        } else {
            nextOutgoingStreamID = streamID &+ 2
        }
        let stream = makeStream(id: streamID, label: label)
        streams[streamID] = stream
        try await sendEnvelope(
            LoomSessionStreamEnvelope(
                kind: .open,
                streamID: streamID,
                label: label,
                payload: nil
            )
        )
        return stream
    }

    /// Creates a direct local datagram priority input endpoint for this
    /// authenticated session.
    public func makePriorityInputEndpoint() throws -> LoomPriorityInputEndpoint {
        guard case .ready = state else {
            throw LoomError.protocolError("Authenticated Loom session is not ready.")
        }
        // TODO: Enable the priority input lane for remote transports after
        // congestion, NAT traversal, and path-health behavior are validated.
        guard transportKind == .udp || transportKind == .quic,
              transport.receiveSemantics == .independentReliableAndUnreliable else {
            throw LoomError.protocolError("Priority input lane is only available on local datagram transports.")
        }
        guard Self.isLocalPriorityInputPath(
            pathSnapshot: currentPathSnapshot,
            remoteEndpoint: remoteEndpoint
        ) else {
            throw LoomError.protocolError("Priority input lane is only available on local datagram transports.")
        }
        guard encryptionEnabled, let securityContext else {
            throw LoomError.protocolError("Priority input lane requires Loom session encryption.")
        }
        return LoomPriorityInputEndpoint(
            securityContext: securityContext,
            sendFrame: { [transport] frame, profile, onComplete in
                await transport.sendUnreliableQueued(
                    frame,
                    profile: profile,
                    onComplete: onComplete
                )
            },
            receiveFrame: { [transport] maxBytes in
                try await transport.receivePriorityUnreliable(maxBytes: maxBytes)
            }
        )
    }

    private static func isLocalPriorityInputPath(
        pathSnapshot: LoomSessionNetworkPathSnapshot?,
        remoteEndpoint: NWEndpoint?
    ) -> Bool {
        if let pathSnapshot {
            let usesLocalInterface = pathSnapshot.usesWiFi ||
                pathSnapshot.usesWiredEthernet ||
                pathSnapshot.usesLoopback ||
                pathSnapshot.interfaceNames.contains(where: Self.isLocalProximityInterfaceName(_:))
            guard usesLocalInterface else { return false }
            return isLocalPriorityInputHost(remoteEndpoint ?? pathSnapshot.remoteEndpoint)
        }

        return isLocalPriorityInputHost(remoteEndpoint)
    }

    private static func isLocalProximityInterfaceName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("anpi") ||
            normalized.hasPrefix("awdl") ||
            normalized.hasPrefix("llw") ||
            normalized.hasPrefix("bridge")
    }

    private static func isLocalPriorityInputHost(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let normalized = "\(host)".lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" { return true }
        if normalized.contains(".local") { return true }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("[fe80:") { return true }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("[fc") { return true }
        if normalized.hasPrefix("fd") || normalized.hasPrefix("[fd") { return true }

        let tokens = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard tokens.count == 4,
              let first = UInt8(tokens[0]),
              let second = UInt8(tokens[1]) else {
            return false
        }

        if first == 127 { return true }
        if first == 10 { return true }
        if first == 192, second == 168 { return true }
        if first == 172, (16 ... 31).contains(second) { return true }
        if first == 169, second == 254 { return true }
        return false
    }

    public func cancel() async {
        finishSession(state: .cancelled, cancelUnderlyingConnection: true)
    }

    private func runReadLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receiveMessage(
                    maxBytes: LoomMessageLimits.maxFrameBytes
                )
                let envelope = try decryptEnvelope(data)
                try await handleEnvelope(envelope, lane: .reliable)
            }
        } catch {
            if case .cancelled = state {
                return
            }
            finishSession(
                state: .failed(error.localizedDescription),
                cancelUnderlyingConnection: true
            )
        }
    }

    private func runUnreliableReadLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receiveUnreliable(
                    maxBytes: LoomMessageLimits.maxFrameBytes
                )
                let envelope = try decryptEnvelope(data)
                try await handleEnvelope(envelope, lane: .unreliable)
            }
        } catch {
            if case .cancelled = state { return }
            if case .failed = state { return }
        }
    }

    private func handleEnvelope(
        _ envelope: LoomSessionStreamEnvelope,
        lane: EnvelopeReceiveLane
    ) async throws {
        switch envelope.kind {
        case .open:
            let stream = makeStream(id: envelope.streamID, label: envelope.label)
            streams[envelope.streamID] = stream
            incomingStreamContinuation.yield(stream)
            incomingStreamObservers.yield(stream)
            flushPendingUnopenedUnreliablePayloads(
                for: envelope.streamID,
                to: stream
            )
        case .data:
            guard let payload = envelope.payload else {
                throw LoomError.protocolError(
                    "Received data envelope with no payload for Loom stream \(envelope.streamID)."
                )
            }
            guard let stream = streams[envelope.streamID] else {
                if recentlyClosedStreamContains(envelope.streamID) {
                    discardPendingUnopenedUnreliablePayloads(
                        for: envelope.streamID,
                        reason: "late-data-after-close"
                    )
                    return
                }
                if lane == .unreliable,
                   transport.receiveSemantics == .independentReliableAndUnreliable {
                    bufferPendingUnopenedUnreliablePayload(
                        payload,
                        for: envelope.streamID
                    )
                    return
                }
                throw LoomError.protocolError("Received data for unknown Loom stream \(envelope.streamID).")
            }
            stream.yield(payload)
        case .close:
            discardPendingUnopenedUnreliablePayloads(
                for: envelope.streamID,
                reason: "stream-closed-before-open"
            )
            guard let stream = streams.removeValue(forKey: envelope.streamID) else {
                return
            }
            markRecentlyClosedStream(envelope.streamID)
            stream.finishInbound()
        }
    }

    private func bufferPendingUnopenedUnreliablePayload(_ payload: Data, for streamID: UInt16) {
        let now = CFAbsoluteTimeGetCurrent()
        evictExpiredPendingUnopenedUnreliablePayloads(now: now)

        var buffer = pendingUnopenedUnreliableDataByStreamID[streamID] ??
            PendingUnopenedUnreliableStreamData(
                payloads: [],
                totalBytes: 0,
                firstBufferedAt: now,
                lastBufferedAt: now
            )
        let nextPayloadCount = buffer.payloads.count + 1
        let nextTotalBytes = buffer.totalBytes + payload.count
        guard nextPayloadCount <= pendingUnopenedUnreliableDataMaxPayloadsPerStream,
              nextTotalBytes <= pendingUnopenedUnreliableDataMaxBytesPerStream else {
            discardPendingUnopenedUnreliablePayloads(
                for: streamID,
                reason: "capacity-exceeded payloads=\(nextPayloadCount) bytes=\(nextTotalBytes)"
            )
            return
        }

        buffer.payloads.append(payload)
        buffer.totalBytes = nextTotalBytes
        buffer.lastBufferedAt = now
        pendingUnopenedUnreliableDataByStreamID[streamID] = buffer
        evictOldestPendingUnopenedUnreliablePayloadsIfNeeded()

        if buffer.payloads.count == 1 {
            LoomLogger.transport(
                "Buffered unreliable payload for unopened Loom stream \(streamID) bytes=\(payload.count)"
            )
        }
    }

    private func flushPendingUnopenedUnreliablePayloads(
        for streamID: UInt16,
        to stream: LoomMultiplexedStream
    ) {
        guard let buffer = pendingUnopenedUnreliableDataByStreamID.removeValue(forKey: streamID) else {
            return
        }

        for payload in buffer.payloads {
            stream.yield(payload)
        }

        let ageMs = Int((CFAbsoluteTimeGetCurrent() - buffer.firstBufferedAt) * 1000)
        LoomLogger.transport(
            "Delivered buffered unreliable payloads for Loom stream \(streamID) count=\(buffer.payloads.count) bytes=\(buffer.totalBytes) ageMs=\(ageMs)"
        )
    }

    private func evictExpiredPendingUnopenedUnreliablePayloads(now: CFAbsoluteTime) {
        guard !pendingUnopenedUnreliableDataByStreamID.isEmpty else { return }

        let expiredStreamIDs = pendingUnopenedUnreliableDataByStreamID.compactMap { streamID, buffer in
            now - buffer.lastBufferedAt >= pendingUnopenedUnreliableDataTTL ? streamID : nil
        }
        for streamID in expiredStreamIDs {
            discardPendingUnopenedUnreliablePayloads(for: streamID, reason: "expired-before-open")
        }
    }

    private func evictOldestPendingUnopenedUnreliablePayloadsIfNeeded() {
        let overflow = pendingUnopenedUnreliableDataByStreamID.count - pendingUnopenedUnreliableDataMaxStreams
        guard overflow > 0 else { return }

        let oldestStreamIDs = pendingUnopenedUnreliableDataByStreamID
            .sorted { lhs, rhs in
                lhs.value.firstBufferedAt < rhs.value.firstBufferedAt
            }
            .prefix(overflow)
            .map(\.key)
        for streamID in oldestStreamIDs {
            discardPendingUnopenedUnreliablePayloads(for: streamID, reason: "stream-cap-exceeded")
        }
    }

    private func discardPendingUnopenedUnreliablePayloads(for streamID: UInt16, reason: String) {
        guard let buffer = pendingUnopenedUnreliableDataByStreamID.removeValue(forKey: streamID) else {
            return
        }

        let ageMs = Int((CFAbsoluteTimeGetCurrent() - buffer.firstBufferedAt) * 1000)
        LoomLogger.transport(
            "Discarded buffered unreliable payloads for unopened Loom stream \(streamID) reason=\(reason) count=\(buffer.payloads.count) bytes=\(buffer.totalBytes) ageMs=\(ageMs)"
        )
    }

    private func markRecentlyClosedStream(_ streamID: UInt16) {
        let now = CFAbsoluteTimeGetCurrent()
        evictExpiredRecentlyClosedStreams(now: now)
        recentlyClosedStreamIDs[streamID] = now
        evictOldestRecentlyClosedStreamsIfNeeded()
    }

    private func recentlyClosedStreamContains(_ streamID: UInt16) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        evictExpiredRecentlyClosedStreams(now: now)
        guard let closedAt = recentlyClosedStreamIDs[streamID] else {
            return false
        }
        if now - closedAt >= recentlyClosedStreamTTL {
            recentlyClosedStreamIDs.removeValue(forKey: streamID)
            return false
        }
        return true
    }

    private func evictExpiredRecentlyClosedStreams(now: CFAbsoluteTime) {
        guard !recentlyClosedStreamIDs.isEmpty else { return }

        let expiredStreamIDs = recentlyClosedStreamIDs.compactMap { streamID, closedAt in
            now - closedAt >= recentlyClosedStreamTTL ? streamID : nil
        }
        for streamID in expiredStreamIDs {
            recentlyClosedStreamIDs.removeValue(forKey: streamID)
        }
    }

    private func evictOldestRecentlyClosedStreamsIfNeeded() {
        let overflow = recentlyClosedStreamIDs.count - recentlyClosedStreamMaxCount
        guard overflow > 0 else { return }

        let oldestStreamIDs = recentlyClosedStreamIDs
            .sorted { lhs, rhs in
                lhs.value < rhs.value
            }
            .prefix(overflow)
            .map(\.key)
        for streamID in oldestStreamIDs {
            recentlyClosedStreamIDs.removeValue(forKey: streamID)
        }
    }

    private func makeStream(id: UInt16, label: String?) -> LoomMultiplexedStream {
        let envelopeForData: @Sendable (Data) -> LoomSessionStreamEnvelope = { data in
            LoomSessionStreamEnvelope(kind: .data, streamID: id, label: nil, payload: data)
        }
        return LoomMultiplexedStream(
            id: id,
            label: label,
            sendHandler: { [weak self] data in
                guard let self else {
                    throw LoomError.protocolError("Authenticated Loom session no longer exists.")
                }
                try await self.sendEnvelope(envelopeForData(data), reliable: true)
            },
            unreliableSendHandler: { [weak self] data in
                guard let self else {
                    throw LoomError.protocolError("Authenticated Loom session no longer exists.")
                }
                try await self.sendEnvelope(envelopeForData(data), reliable: false)
            },
            queuedUnreliableSendHandler: { [weak self] data, profile, options, onComplete in
                guard let self else {
                    onComplete(
                        LoomError.protocolError("Authenticated Loom session no longer exists.")
                    )
                    return
                }
                await self.sendEnvelopeQueued(
                    envelopeForData(data),
                    profile: profile,
                    options: options,
                    onComplete: onComplete
                )
            },
            queuedUnreliableResetHandler: { [weak self] profile in
                guard let self else { return }
                await self.transport.resetQueuedUnreliableSends(profile: profile)
            },
            queuedUnreliableDiagnosticsHandler: { [weak self] profile in
                guard let self else { return nil }
                return await self.transport.consumeQueuedUnreliableSendDiagnostics(profile: profile)
            },
            closeHandler: { [weak self] in
                guard let self else {
                    throw LoomError.protocolError("Authenticated Loom session no longer exists.")
                }
                try await self.sendEnvelope(
                    LoomSessionStreamEnvelope(
                        kind: .close,
                        streamID: id,
                        label: nil,
                        payload: nil
                    )
                )
                await self.removeStream(id: id)
            }
        )
    }

    private func removeStream(id: UInt16) {
        guard streams.removeValue(forKey: id) != nil else {
            return
        }
        markRecentlyClosedStream(id)
    }

    private func sendEnvelope(
        _ envelope: LoomSessionStreamEnvelope,
        reliable: Bool = true
    ) async throws {
        let wireFrame = try encodeWireFrame(for: envelope)

        if reliable {
            try await transport.sendMessage(wireFrame)
        } else {
            try await transport.sendUnreliable(wireFrame)
        }
    }

    private func sendEnvelopeQueued(
        _ envelope: LoomSessionStreamEnvelope,
        profile: LoomQueuedUnreliableSendProfile,
        options: LoomQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) async {
        if profile.requiresIndependentUnreliableLane,
           transport.receiveSemantics != .independentReliableAndUnreliable {
            onComplete(
                LoomQueuedUnreliableSendDrop(
                    reason: .unsupportedTransport,
                    profile: profile,
                    frameID: options.frameID,
                    fragmentIndex: options.fragmentIndex,
                    fragmentCount: options.fragmentCount
                )
            )
            return
        }

        do {
            let wireFrame = try encodeWireFrame(for: envelope)
            await transport.sendUnreliableQueued(
                wireFrame,
                profile: profile,
                options: options,
                onComplete: onComplete
            )
        } catch {
            onComplete(error)
        }
    }

    private func encodeWireFrame(for envelope: LoomSessionStreamEnvelope) throws -> Data {
        let trafficClass = envelope.kind == .data ? LoomSessionTrafficClass.data : .control
        let encodedEnvelope = try envelope.encode()

        let wireFrame: Data
        if encryptionEnabled {
            guard let securityContext else {
                throw LoomError.protocolError("Authenticated Loom session encryption context is unavailable.")
            }
            let encryptedPayload = try securityContext.seal(
                encodedEnvelope,
                trafficClass: trafficClass
            )
            var frame = Data(capacity: encryptedPayload.count + 1)
            frame.append(trafficClass.rawValue)
            frame.append(encryptedPayload)
            wireFrame = frame
        } else {
            var frame = Data(capacity: encodedEnvelope.count + 1)
            frame.append(0x00)
            frame.append(encodedEnvelope)
            wireFrame = frame
        }
        return wireFrame
    }

    private func decryptEnvelope(_ wireFrame: Data) throws -> LoomSessionStreamEnvelope {
        guard let firstByte = wireFrame.first else {
            throw LoomError.protocolError("Received empty Loom session frame.")
        }

        if firstByte == 0x00 {
            guard !encryptionEnabled else {
                throw LoomError.protocolError("Received unencrypted frame on encrypted Loom session.")
            }
            return try LoomSessionStreamEnvelope.decode(from: Data(wireFrame.dropFirst()))
        }

        guard encryptionEnabled else {
            throw LoomError.protocolError("Received encrypted frame on unencrypted Loom session.")
        }
        guard let trafficClass = LoomSessionTrafficClass(rawValue: firstByte) else {
            throw LoomError.protocolError("Received Loom session frame with invalid traffic class.")
        }
        guard let securityContext else {
            throw LoomError.protocolError("Authenticated Loom session encryption context is unavailable.")
        }
        let plaintext = try securityContext.open(
            Data(wireFrame.dropFirst()),
            trafficClass: trafficClass
        )
        return try LoomSessionStreamEnvelope.decode(from: plaintext)
    }

    private func resolveTrustEvaluation(
        for peerIdentity: LoomPeerIdentity,
        trustProvider: (any LoomTrustProvider)?
    ) async -> LoomTrustEvaluation {
        guard let trustProvider else {
            return LoomTrustEvaluation(
                decision: .requiresApproval,
                shouldShowAutoTrustNotice: false
            )
        }
        return await trustProvider.evaluateTrustOutcome(for: peerIdentity)
    }

    // MARK: - Handshake Trust Status Signaling

    /// Receiver (host) side: evaluate trust, signaling the peer if approval is pending.
    ///
    /// If trust resolves within 500ms, only the final status is sent.
    /// If trust takes longer (e.g., manual approval dialog), a `.pendingApproval`
    /// frame is sent first so the client can show a waiting indicator.
    private func resolveAndSignalTrust(
        for peerIdentity: LoomPeerIdentity,
        trustProvider: (any LoomTrustProvider)?
    ) async throws -> LoomTrustEvaluation {
        let evaluation: LoomTrustEvaluation = await withTaskGroup(
            of: LoomTrustEvaluation?.self
        ) { group in
            group.addTask {
                await self.resolveTrustEvaluation(
                    for: peerIdentity,
                    trustProvider: trustProvider
                )
            }

            group.addTask { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return nil }
                await self.updateBootstrapProgress(phase: .trustPendingApproval)
                try? await self.sendTrustStatus(.pendingApproval)
                return nil
            }

            var result: LoomTrustEvaluation?
            for await value in group {
                if let value {
                    result = value
                    group.cancelAll()
                    break
                }
            }
            return result ?? LoomTrustEvaluation(
                decision: .denied,
                shouldShowAutoTrustNotice: false
            )
        }

        let finalStatus: LoomHandshakeTrustStatus =
            evaluation.decision == .trusted ? .trusted : .denied
        try await sendTrustStatus(finalStatus)
        return evaluation
    }

    /// Initiator (client) side: receive trust status frames from the host.
    private func receiveHostTrustStatus() async throws -> LoomTrustEvaluation {
        while true {
            let data = try await transport.receiveMessage(
                maxBytes: LoomMessageLimits.maxTrustStatusFrameBytes
            )
            let status = try JSONDecoder().decode(
                LoomHandshakeTrustStatus.self,
                from: data
            )
            switch status {
            case .pendingApproval:
                updateBootstrapProgress(phase: .trustPendingApproval)
                await onTrustPending?()
                continue
            case .trusted:
                return LoomTrustEvaluation(
                    decision: .trusted,
                    shouldShowAutoTrustNotice: false
                )
            case .denied:
                return LoomTrustEvaluation(
                    decision: .denied,
                    shouldShowAutoTrustNotice: false
                )
            }
        }
    }

    private func sendTrustStatus(_ status: LoomHandshakeTrustStatus) async throws {
        let data = try JSONEncoder().encode(status)
        try await transport.sendMessage(data)
    }

    private func updateState(_ newState: LoomAuthenticatedSessionState) {
        state = newState
        stateObservers.yield(newState)
    }

    private func updateBootstrapProgress(
        phase: LoomAuthenticatedSessionBootstrapPhase,
        failureReason: String? = nil
    ) {
        let progress = LoomAuthenticatedSessionBootstrapProgress(
            phase: phase,
            failureReason: failureReason
        )
        bootstrapProgress = progress
        bootstrapProgressObservers.yield(progress)
        onBootstrapProgress?(progress)
    }

    private func updateBootstrapFailure(reason: String) {
        guard bootstrapProgress.phase != .ready else { return }
        updateBootstrapProgress(
            phase: bootstrapProgress.phase == .idle ? .transportStarting : bootstrapProgress.phase,
            failureReason: reason
        )
    }

    private func configureTransportObserversIfNeeded() {
        guard !transportObserversConfigured else { return }
        transportObserversConfigured = true
        guard let nwConnection else {
            currentRemoteEndpoint = quicRemoteEndpoint
            if let snapshot = quicPathSnapshotProvider?() {
                applyTransportPathSnapshot(snapshot)
            }
            Task { [weak self, transport] in
                await transport.setObservationHandler { [weak self] observation in
                    Task {
                        await self?.handleTransportObservation(observation)
                    }
                }
            }
            return
        }
        currentRemoteEndpoint = nwConnection.endpoint

        if let path = nwConnection.currentPath {
            applyTransportPathSnapshot(LoomSessionNetworkPathSnapshot(path: path))
        }

        nwConnection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task {
                await self.handleTransportPathUpdate(path)
            }
        }
        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handleUnderlyingConnectionState(state)
            }
        }
    }

    private func handleTransportObservation(_ observation: LoomSessionTransportObservation) {
        switch observation {
        case let .path(snapshot):
            applyTransportPathSnapshot(snapshot)
        case let .failed(reason):
            if case .failed = state { return }
            if case .cancelled = state { return }
            finishSession(
                state: .failed(reason),
                cancelUnderlyingConnection: false
            )
        case .cancelled:
            if case .cancelled = state { return }
            if case .failed = state { return }
            finishSession(state: .cancelled, cancelUnderlyingConnection: false)
        }
    }

    private func handleTransportPathUpdate(_ path: NWPath) {
        applyTransportPathSnapshot(LoomSessionNetworkPathSnapshot(path: path))
    }

    private func applyTransportPathSnapshot(_ snapshot: LoomSessionNetworkPathSnapshot) {
        currentPathSnapshot = snapshot
        if let remoteEndpoint = snapshot.remoteEndpoint {
            currentRemoteEndpoint = remoteEndpoint
        }
        pathObservers.yield(snapshot)
    }

    private func handleUnderlyingConnectionState(_ connectionState: NWConnection.State) {
        switch connectionState {
        case let .failed(error):
            if case .failed = state { return }
            if case .cancelled = state { return }
            finishSession(
                state: .failed(error.localizedDescription),
                cancelUnderlyingConnection: false
            )
        case .cancelled:
            if case .cancelled = state { return }
            if case .failed = state { return }
            finishSession(state: .cancelled, cancelUnderlyingConnection: false)
        default:
            break
        }
    }

    private func finishSession(
        state newState: LoomAuthenticatedSessionState,
        cancelUnderlyingConnection: Bool
    ) {
        switch state {
        case .cancelled, .failed:
            return
        default:
            break
        }

        updateState(newState)
        readTask?.cancel()
        unreliableReadTask?.cancel()
        for stream in streams.values {
            stream.finishQueuedOutbound()
            stream.finishInbound()
        }
        streams.removeAll(keepingCapacity: false)
        pendingUnopenedUnreliableDataByStreamID.removeAll(keepingCapacity: false)
        recentlyClosedStreamIDs.removeAll(keepingCapacity: false)
        incomingStreamContinuation.finish()
        incomingStreamObservers.finish()
        stateObservers.finish()
        bootstrapProgressObservers.finish()
        pathObservers.finish()
        if cancelUnderlyingConnection {
            Task {
                await transport.closeTransport()
            }
            connection.backingNWConnection?.cancel()
        } else {
            Task {
                await transport.cancelPendingUnreliableSends()
            }
        }
    }

    package func setNextOutgoingStreamIDForTesting(_ value: UInt16) {
        nextOutgoingStreamID = value
    }

    package func injectUnreliableDataForTesting(streamID: UInt16, payload: Data) async throws {
        try await handleEnvelope(
            LoomSessionStreamEnvelope(
                kind: .data,
                streamID: streamID,
                label: nil,
                payload: payload
            ),
            lane: .unreliable
        )
    }

    package func injectReliableDataForTesting(streamID: UInt16, payload: Data) async throws {
        try await handleEnvelope(
            LoomSessionStreamEnvelope(
                kind: .data,
                streamID: streamID,
                label: nil,
                payload: payload
            ),
            lane: .reliable
        )
    }

    package func injectOpenForTesting(streamID: UInt16, label: String? = nil) async throws {
        try await handleEnvelope(
            LoomSessionStreamEnvelope(
                kind: .open,
                streamID: streamID,
                label: label,
                payload: nil
            ),
            lane: .reliable
        )
    }

    package func injectCloseForTesting(streamID: UInt16) async throws {
        try await handleEnvelope(
            LoomSessionStreamEnvelope(
                kind: .close,
                streamID: streamID,
                label: nil,
                payload: nil
            ),
            lane: .reliable
        )
    }
}

private enum LoomSessionStreamEnvelopeKind: UInt8 {
    case open
    case data
    case close
}

private struct LoomSessionStreamEnvelope: Sendable {
    let kind: LoomSessionStreamEnvelopeKind
    let streamID: UInt16
    let label: String?
    let payload: Data?

    func encode() throws -> Data {
        let labelBytes = label?.data(using: .utf8) ?? Data()
        let payloadBytes = payload ?? Data()
        guard labelBytes.count <= LoomMessageLimits.maxStreamLabelBytes else {
            throw LoomError.protocolError(
                "Authenticated Loom stream labels must not exceed \(LoomMessageLimits.maxStreamLabelBytes) UTF-8 bytes."
            )
        }
        let labelLength = UInt16(labelBytes.count)
        let payloadLength = UInt32(clamping: payloadBytes.count)

        var data = Data(capacity: 1 + 2 + 2 + 4 + labelBytes.count + payloadBytes.count)
        data.append(kind.rawValue)
        data.append(contentsOf: streamID.littleEndianBytes)
        data.append(contentsOf: labelLength.littleEndianBytes)
        data.append(contentsOf: payloadLength.littleEndianBytes)
        data.append(labelBytes)
        data.append(payloadBytes)
        return data
    }

    static func decode(from data: Data) throws -> LoomSessionStreamEnvelope {
        var cursor = 0
        guard data.count >= 9,
              let kind = LoomSessionStreamEnvelopeKind(rawValue: data[cursor]) else {
            throw LoomError.protocolError("Received invalid Loom stream envelope header.")
        }
        cursor += 1

        let streamID = try readUInt16(from: data, cursor: &cursor)
        let labelLength = Int(try readUInt16(from: data, cursor: &cursor))
        let payloadLength = Int(try readUInt32(from: data, cursor: &cursor))
        let requiredLength = cursor + labelLength + payloadLength
        guard data.count == requiredLength else {
            throw LoomError.protocolError("Received malformed Loom stream envelope length.")
        }

        let label: String?
        if labelLength > 0 {
            let labelData = data[cursor..<(cursor + labelLength)]
            label = String(data: labelData, encoding: .utf8)
            cursor += labelLength
        } else {
            label = nil
        }

        let payload: Data?
        if payloadLength > 0 {
            payload = Data(data[cursor..<(cursor + payloadLength)])
        } else {
            payload = nil
        }

        return LoomSessionStreamEnvelope(
            kind: kind,
            streamID: streamID,
            label: label,
            payload: payload
        )
    }

    private static func readUInt16(from data: Data, cursor: inout Int) throws -> UInt16 {
        let length = MemoryLayout<UInt16>.size
        guard data.count >= cursor + length else {
            throw LoomError.protocolError("Received truncated Loom stream envelope.")
        }
        let value =
            UInt16(data[cursor]) |
            (UInt16(data[cursor + 1]) << 8)
        cursor += length
        return value
    }

    private static func readUInt32(from data: Data, cursor: inout Int) throws -> UInt32 {
        let length = MemoryLayout<UInt32>.size
        guard data.count >= cursor + length else {
            throw LoomError.protocolError("Received truncated Loom stream envelope.")
        }
        let value =
            UInt32(data[cursor]) |
            (UInt32(data[cursor + 1]) << 8) |
            (UInt32(data[cursor + 2]) << 16) |
            (UInt32(data[cursor + 3]) << 24)
        cursor += length
        return value
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
