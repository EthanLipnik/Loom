//
//  LoomTransferEngine.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Handle for an app-owned outgoing Loom transfer.
public final class LoomOutgoingTransfer: @unchecked Sendable {
    /// Transfer offer originally sent to the remote peer.
    public let offer: LoomTransferOffer
    /// Async progress stream for the transfer lifecycle.
    public let progressEvents: AsyncStream<LoomTransferProgress>

    private let cancelHandler: @Sendable () async -> Void
    private let progressContinuation: AsyncStream<LoomTransferProgress>.Continuation
    private let progressObservers = LoomAsyncBroadcaster<LoomTransferProgress>(
        bufferingPolicy: .bufferingNewest(1)
    )
    private let progressLock = NSLock()
    private var lastProgress: LoomTransferProgress?
    private var isTerminal = false

    fileprivate init(
        offer: LoomTransferOffer,
        cancelHandler: @escaping @Sendable () async -> Void
    ) {
        self.offer = offer
        self.cancelHandler = cancelHandler
        let (stream, continuation) = AsyncStream.makeStream(
            of: LoomTransferProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        progressEvents = stream
        progressContinuation = continuation
    }

    /// Cancels the outgoing transfer and notifies the remote peer.
    public func cancel() async {
        await cancelHandler()
    }

    /// Creates an additional observation stream for transfer progress updates.
    public nonisolated func makeProgressObserver() -> AsyncStream<LoomTransferProgress> {
        progressObservers.makeStream()
    }

    fileprivate func yield(_ progress: LoomTransferProgress) {
        progressLock.lock()
        guard !isTerminal, progress != lastProgress else {
            progressLock.unlock()
            return
        }
        lastProgress = progress
        let isTerminal = progress.state == .completed ||
            progress.state == .cancelled ||
            progress.state == .failed ||
            progress.state == .declined
        self.isTerminal = isTerminal
        progressLock.unlock()

        progressContinuation.yield(progress)
        progressObservers.yield(progress)
        if isTerminal {
            progressContinuation.finish()
            progressObservers.finish()
        }
    }
}

/// Handle for an incoming Loom transfer offered by a remote peer.
public final class LoomIncomingTransfer: @unchecked Sendable {
    /// Transfer offer supplied by the remote peer.
    public let offer: LoomTransferOffer
    /// Async progress stream for the transfer lifecycle.
    public let progressEvents: AsyncStream<LoomTransferProgress>

    private let acceptHandler: @Sendable (any LoomTransferSink, UInt64) async throws -> Void
    private let declineHandler: @Sendable () async throws -> Void
    private let progressContinuation: AsyncStream<LoomTransferProgress>.Continuation
    private let progressObservers = LoomAsyncBroadcaster<LoomTransferProgress>(
        bufferingPolicy: .bufferingNewest(1)
    )
    private let progressLock = NSLock()
    private var lastProgress: LoomTransferProgress?
    private var isTerminal = false

    fileprivate init(
        offer: LoomTransferOffer,
        acceptHandler: @escaping @Sendable (any LoomTransferSink, UInt64) async throws -> Void,
        declineHandler: @escaping @Sendable () async throws -> Void
    ) {
        self.offer = offer
        self.acceptHandler = acceptHandler
        self.declineHandler = declineHandler
        let (stream, continuation) = AsyncStream.makeStream(
            of: LoomTransferProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        progressEvents = stream
        progressContinuation = continuation
    }

    /// Accepts the offered transfer and begins or resumes writing into `sink`.
    public func accept(
        using sink: any LoomTransferSink,
        resumeOffset: UInt64 = 0
    ) async throws {
        try await acceptHandler(sink, resumeOffset)
    }

    /// Declines the offered transfer and notifies the remote peer.
    public func decline() async throws {
        try await declineHandler()
    }

    /// Creates an additional observation stream for transfer progress updates.
    public nonisolated func makeProgressObserver() -> AsyncStream<LoomTransferProgress> {
        progressObservers.makeStream()
    }

    fileprivate func yield(_ progress: LoomTransferProgress) {
        progressLock.lock()
        guard !isTerminal, progress != lastProgress else {
            progressLock.unlock()
            return
        }
        lastProgress = progress
        let isTerminal = progress.state == .completed ||
            progress.state == .cancelled ||
            progress.state == .failed ||
            progress.state == .declined
        self.isTerminal = isTerminal
        progressLock.unlock()

        progressContinuation.yield(progress)
        progressObservers.yield(progress)
        if isTerminal {
            progressContinuation.finish()
            progressObservers.finish()
        }
    }
}

/// Generic resumable bulk object transfer layered on an authenticated Loom session.
public actor LoomTransferEngine {
    private struct PendingDataStreamState {
        let stream: LoomMultiplexedStream
        let insertedAt: ContinuousClock.Instant
        let expirationTask: Task<Void, Never>
    }

    /// Authenticated Loom session used for encrypted control and data streams.
    public let session: any LoomSessionProtocol
    /// Transfer scheduling configuration used by the engine.
    public let configuration: LoomTransferConfiguration
    /// Async stream of remote transfer offers that arrive on the session.
    public nonisolated let incomingTransfers: AsyncStream<LoomIncomingTransfer>

    private let incomingTransfersContinuation: AsyncStream<LoomIncomingTransfer>.Continuation
    private var outboundControlStream: LoomMultiplexedStream?
    private var hasInboundControlStream = false
    private var controlStreamTask: Task<Void, Never>?
    private var outgoingTransfers: [UUID: OutgoingTransferState] = [:]
    private var incomingTransfersByID: [UUID: IncomingTransferState] = [:]
    private var pendingDataStreams: [UUID: PendingDataStreamState] = [:]
    private let scheduler: LoomTransferScheduler

    /// Creates a transfer engine bound to one authenticated Loom session.
    public init(
        session: any LoomSessionProtocol,
        configuration: LoomTransferConfiguration = .default
    ) {
        self.session = session
        self.configuration = configuration
        scheduler = LoomTransferScheduler(configuration: configuration)
        let (stream, continuation) = AsyncStream.makeStream(
            of: LoomIncomingTransfer.self,
            bufferingPolicy: .bufferingOldest(configuration.maxActiveTransfersPerDirection)
        )
        incomingTransfers = stream
        incomingTransfersContinuation = continuation
        Task { [weak self] in
            await self?.observeIncomingStreams()
        }
    }

    deinit {
        controlStreamTask?.cancel()
        pendingDataStreams.values.forEach { $0.expirationTask.cancel() }
        outgoingTransfers.values.forEach {
            $0.offerDecisionTask?.cancel()
            $0.completionDeadlineTask?.cancel()
            $0.task?.cancel()
        }
        incomingTransfersByID.values.forEach {
            $0.offerDecisionTask?.cancel()
            $0.completionDeadlineTask?.cancel()
            $0.task?.cancel()
        }
        incomingTransfersContinuation.finish()
    }

    package var pendingDataStreamCount: Int {
        pendingDataStreams.count
    }

    package var incomingTransferCount: Int {
        incomingTransfersByID.count
    }

    package var outgoingTransferCount: Int {
        outgoingTransfers.count
    }

    /// Offers one opaque object to the remote peer and returns a progress handle.
    public func offerTransfer(
        _ offer: LoomTransferOffer,
        source: any LoomTransferSource
    ) async throws -> LoomOutgoingTransfer {
        try validate(offer: offer)
        guard source.byteLength == offer.byteLength else {
            throw LoomTransferError.protocolViolation(
                "Transfer source length did not match the advertised byte length."
            )
        }
        guard outgoingTransfers[offer.id] == nil else {
            throw LoomTransferError.protocolViolation("Duplicate outgoing Loom transfer identifier.")
        }
        guard outgoingTransfers.count < configuration.maxActiveTransfersPerDirection else {
            throw LoomTransferError.protocolViolation("Too many active outgoing Loom transfers.")
        }
        let progressHandle = LoomOutgoingTransfer(offer: offer) { [weak self] in
            await self?.cancelOutgoingTransfer(id: offer.id)
        }
        let offerDecisionTimeout = configuration.offerDecisionTimeout
        let offerDecisionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: offerDecisionTimeout)
            } catch {
                return
            }
            await self?.expireOutgoingOfferDecision(id: offer.id)
        }
        outgoingTransfers[offer.id] = OutgoingTransferState(
            offer: offer,
            source: source,
            handle: progressHandle,
            offerDecisionTask: offerDecisionTask
        )
        progressHandle.yield(progress(for: offer, bytesTransferred: 0, state: .offered))
        do {
            try await sendControlMessage(
                LoomTransferControlMessage(
                    kind: .offer,
                    transferID: offer.id,
                    offer: offer
                )
            )
        } catch {
            outgoingTransfers.removeValue(forKey: offer.id)?.offerDecisionTask?.cancel()
            progressHandle.yield(progress(for: offer, bytesTransferred: 0, state: .failed))
            throw error
        }
        progressHandle.yield(progress(for: offer, bytesTransferred: 0, state: .waitingForAcceptance))
        LoomInstrumentation.record("loom.transfer.offer")
        LoomLogger.debug(
            .transfer,
            "Offered Loom transfer logicalName=\(offer.logicalName) bytes=\(offer.byteLength)"
        )
        return progressHandle
    }

    private func observeIncomingStreams() async {
        for await stream in session.makeIncomingStreamObserver() {
            guard let label = stream.label else {
                continue
            }
            if label == Self.controlStreamLabel {
                guard !hasInboundControlStream else {
                    LoomLogger.log(.transfer, "Rejected duplicate inbound Loom transfer control stream.")
                    try? await stream.close()
                    continue
                }
                hasInboundControlStream = true
                controlStreamTask = Task { [weak self] in
                    await self?.consumeControlStream(stream)
                }
                continue
            }
            guard let transferID = Self.transferID(fromDataStreamLabel: label) else {
                continue
            }
            guard pendingDataStreams[transferID] == nil else {
                LoomLogger.log(
                    .transfer,
                    "Rejected duplicate pending Loom transfer data stream id=\(transferID.uuidString)"
                )
                try? await stream.close()
                continue
            }
            if pendingDataStreams.count >= configuration.maxPendingDataStreams,
               let oldestTransferID = pendingDataStreams.min(by: {
                   $0.value.insertedAt < $1.value.insertedAt
               })?.key {
                await discardPendingDataStream(id: oldestTransferID, reason: "capacity-eviction")
            }
            let pendingDataStreamTimeout = configuration.pendingDataStreamTimeout
            let expirationTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: pendingDataStreamTimeout)
                } catch {
                    return
                }
                await self?.discardPendingDataStream(id: transferID, reason: "offer-timeout")
            }
            pendingDataStreams[transferID] = PendingDataStreamState(
                stream: stream,
                insertedAt: .now,
                expirationTask: expirationTask
            )
            if let incomingState = incomingTransfersByID[transferID],
               incomingState.isAccepted {
                await attachPendingDataStream(to: transferID)
            }
        }
    }

    private func consumeControlStream(_ stream: LoomMultiplexedStream) async {
        for await payload in stream.incomingBytes {
            guard payload.count <= configuration.maxControlMessageBytes else {
                let error = LoomTransferError.protocolViolation(
                    "Transfer control message exceeds the configured encoded byte limit."
                )
                LoomDiagnostics.report(
                    error: error,
                    category: .transfer,
                    message: "Transfer control message failed: \(error.localizedDescription)"
                )
                try? await stream.close()
                break
            }
            do {
                let message = try JSONDecoder().decode(LoomTransferControlMessage.self, from: payload)
                try await handleControlMessage(message)
            } catch {
                LoomDiagnostics.report(
                    error: error,
                    category: .transfer,
                    message: "Transfer control message failed: \(error.localizedDescription)"
                )
            }
        }
        for (id, state) in incomingTransfersByID where !state.isControlComplete {
            incomingTransfersByID.removeValue(forKey: id)
            state.offerDecisionTask?.cancel()
            state.completionDeadlineTask?.cancel()
            state.task?.cancel()
            try? await state.sink?.close()
            state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesReceived, state: .failed))
        }
        for (id, state) in outgoingTransfers {
            outgoingTransfers.removeValue(forKey: id)
            state.offerDecisionTask?.cancel()
            state.completionDeadlineTask?.cancel()
            state.task?.cancel()
            try? await state.dataStream?.close()
            await scheduler.finishTransfer(id: id)
            state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesTransferred, state: .failed))
        }
        for transferID in Array(pendingDataStreams.keys) {
            await discardPendingDataStream(id: transferID, reason: "control-stream-closed")
        }
        incomingTransfersContinuation.finish()
    }

    private func handleControlMessage(_ message: LoomTransferControlMessage) async throws {
        switch message.kind {
        case .offer:
            guard let offer = message.offer else {
                throw LoomTransferError.protocolViolation("Missing Loom transfer offer payload.")
            }
            do {
                try validate(offer: offer)
                guard incomingTransfersByID[offer.id] == nil else {
                    throw LoomTransferError.protocolViolation("Duplicate incoming Loom transfer identifier.")
                }
                guard incomingTransfersByID.count < configuration.maxActiveTransfersPerDirection else {
                    throw LoomTransferError.protocolViolation("Too many active incoming Loom transfers.")
                }
            } catch {
                await discardPendingDataStream(id: offer.id, reason: "invalid-offer")
                try? await sendControlMessage(
                    LoomTransferControlMessage(kind: .decline, transferID: offer.id)
                )
                throw error
            }
            let incoming = LoomIncomingTransfer(
                offer: offer,
                acceptHandler: { [weak self] sink, resumeOffset in
                    guard let self else { return }
                    try await self.acceptIncomingTransfer(
                        id: offer.id,
                        sink: sink,
                        resumeOffset: resumeOffset
                    )
                },
                declineHandler: { [weak self] in
                    guard let self else { return }
                    try await self.declineIncomingTransfer(id: offer.id)
                }
            )
            let offerDecisionTimeout = configuration.offerDecisionTimeout
            let offerDecisionTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: offerDecisionTimeout)
                } catch {
                    return
                }
                await self?.expireIncomingOfferDecision(id: offer.id)
            }
            incomingTransfersByID[offer.id] = IncomingTransferState(
                offer: offer,
                handle: incoming,
                offerDecisionTask: offerDecisionTask
            )
            incoming.yield(progress(for: offer, bytesTransferred: 0, state: .offered))
            let yieldResult = incomingTransfersContinuation.yield(incoming)
            switch yieldResult {
            case .enqueued:
                break
            case .dropped:
                incomingTransfersByID.removeValue(forKey: offer.id)?.offerDecisionTask?.cancel()
                incoming.yield(progress(for: offer, bytesTransferred: 0, state: .declined))
                await discardPendingDataStream(id: offer.id, reason: "offer-buffer-full")
                try? await sendControlMessage(
                    LoomTransferControlMessage(kind: .decline, transferID: offer.id)
                )
                throw LoomTransferError.protocolViolation("Incoming Loom transfer offer buffer is full.")
            case .terminated:
                incomingTransfersByID.removeValue(forKey: offer.id)?.offerDecisionTask?.cancel()
                incoming.yield(progress(for: offer, bytesTransferred: 0, state: .declined))
                await discardPendingDataStream(id: offer.id, reason: "offer-stream-terminated")
                try? await sendControlMessage(
                    LoomTransferControlMessage(kind: .decline, transferID: offer.id)
                )
                throw LoomTransferError.protocolViolation("Incoming Loom transfer offer stream is unavailable.")
            @unknown default:
                incomingTransfersByID.removeValue(forKey: offer.id)?.offerDecisionTask?.cancel()
                incoming.yield(progress(for: offer, bytesTransferred: 0, state: .declined))
                await discardPendingDataStream(id: offer.id, reason: "offer-delivery-failed")
                try? await sendControlMessage(
                    LoomTransferControlMessage(kind: .decline, transferID: offer.id)
                )
                throw LoomTransferError.protocolViolation("Incoming Loom transfer offer delivery failed.")
            }
            LoomInstrumentation.record("loom.transfer.incoming_offer")
            LoomLogger.debug(
                .transfer,
                "Received Loom transfer offer logicalName=\(offer.logicalName) bytes=\(offer.byteLength)"
            )

        case .accept:
            guard let transferID = message.transferID,
                  let resumeOffset = message.resumeOffset else {
                throw LoomTransferError.protocolViolation("Missing Loom transfer accept state.")
            }
            try await startOutgoingTransfer(id: transferID, resumeOffset: resumeOffset)

        case .decline:
            guard let transferID = message.transferID,
                  let state = outgoingTransfers.removeValue(forKey: transferID) else {
                return
            }
            await scheduler.finishTransfer(id: transferID)
            state.offerDecisionTask?.cancel()
            state.completionDeadlineTask?.cancel()
            recordTransferStep(
                "loom.transfer.declined.remote.\(resumeMode(for: state.bytesTransferred))"
            )
            LoomLogger.log(
                .transfer,
                "Remote peer declined Loom transfer logicalName=\(state.offer.logicalName) bytesTransferred=\(state.bytesTransferred)"
            )
            state.task?.cancel()
            try? await state.dataStream?.close()
            state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesTransferred, state: .declined))

        case .cancel:
            guard let transferID = message.transferID else {
                return
            }
            if let outgoing = outgoingTransfers.removeValue(forKey: transferID) {
                await scheduler.finishTransfer(id: transferID)
                outgoing.offerDecisionTask?.cancel()
                outgoing.completionDeadlineTask?.cancel()
                recordTransferStep("loom.transfer.cancel.remote.outgoing")
                LoomLogger.log(
                    .transfer,
                    "Remote peer cancelled outgoing Loom transfer logicalName=\(outgoing.offer.logicalName) bytesTransferred=\(outgoing.bytesTransferred)"
                )
                outgoing.task?.cancel()
                try? await outgoing.dataStream?.close()
                outgoing.handle.yield(progress(for: outgoing.offer, bytesTransferred: outgoing.bytesTransferred, state: .cancelled))
            }
            if let incoming = incomingTransfersByID.removeValue(forKey: transferID) {
                incoming.offerDecisionTask?.cancel()
                incoming.completionDeadlineTask?.cancel()
                recordTransferStep("loom.transfer.cancel.remote.incoming")
                LoomLogger.log(
                    .transfer,
                    "Remote peer cancelled incoming Loom transfer logicalName=\(incoming.offer.logicalName) bytesTransferred=\(incoming.bytesReceived)"
                )
                incoming.task?.cancel()
                try? await incoming.sink?.close()
                incoming.handle.yield(progress(for: incoming.offer, bytesTransferred: incoming.bytesReceived, state: .cancelled))
            }
            await discardPendingDataStream(id: transferID, reason: "transfer-cancelled")

        case .complete:
            guard let transferID = message.transferID else {
                return
            }
            if var incoming = incomingTransfersByID[transferID] {
                incoming.isControlComplete = true
                incoming.expectedSHA256Hex = message.sha256Hex ?? incoming.offer.sha256Hex
                incomingTransfersByID[transferID] = incoming
                do {
                    try await finalizeIncomingTransferIfPossible(id: transferID)
                } catch {
                    if let failedState = incomingTransfersByID.removeValue(forKey: transferID) {
                        failedState.offerDecisionTask?.cancel()
                        failedState.completionDeadlineTask?.cancel()
                        failedState.task?.cancel()
                        try? await failedState.sink?.close()
                        failedState.handle.yield(progress(for: failedState.offer, bytesTransferred: failedState.bytesReceived, state: .failed))
                    }
                    throw error
                }
            }
        }
    }

    private func ensureControlStream() async throws -> LoomMultiplexedStream {
        if let outboundControlStream {
            return outboundControlStream
        }
        let stream = try await session.openStream(label: Self.controlStreamLabel)
        outboundControlStream = stream
        return stream
    }

    private func sendControlMessage(_ message: LoomTransferControlMessage) async throws {
        let stream = try await ensureControlStream()
        let payload = try JSONEncoder().encode(message)
        try validateControlPayloadSize(payload)
        try await stream.send(payload)
    }

    private func acceptIncomingTransfer(
        id: UUID,
        sink: any LoomTransferSink,
        resumeOffset: UInt64
    ) async throws {
        guard var state = incomingTransfersByID[id] else {
            throw LoomTransferError.missingTransferState
        }
        guard !state.isAccepted else {
            throw LoomTransferError.protocolViolation("Incoming Loom transfer was already accepted.")
        }
        guard resumeOffset <= state.offer.byteLength else {
            incomingTransfersByID.removeValue(forKey: id)
            state.offerDecisionTask?.cancel()
            try? await sink.close()
            state.handle.yield(
                progress(
                    for: state.offer,
                    bytesTransferred: state.bytesReceived,
                    state: .failed
                )
            )
            await discardPendingDataStream(id: id, reason: "invalid-resume-offset")
            try? await sendControlMessage(
                LoomTransferControlMessage(kind: .cancel, transferID: id)
            )
            throw LoomTransferError.protocolViolation(
                "Invalid Loom transfer resume offset \(resumeOffset) for byteLength \(state.offer.byteLength)."
            )
        }
        state.offerDecisionTask?.cancel()
        state.offerDecisionTask = nil
        state.sink = sink
        state.resumeOffset = resumeOffset
        state.bytesReceived = resumeOffset
        state.isAccepted = true
        state.expectedSHA256Hex = state.offer.sha256Hex
        if resumeOffset == 0 {
            state.receivedHasher = SHA256()
        }
        state.acceptedAt = Date()
        let activeTransferTimeout = configuration.activeTransferTimeout
        state.completionDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: activeTransferTimeout)
            } catch {
                return
            }
            await self?.expireIncomingActiveTransfer(id: id)
        }
        incomingTransfersByID[id] = state

        do {
            try await sink.truncate(to: resumeOffset)
            guard incomingTransfersByID[id] != nil else {
                throw LoomTransferError.missingTransferState
            }
            state.handle.yield(progress(for: state.offer, bytesTransferred: resumeOffset, state: .waitingForAcceptance))
            recordTransferStep("loom.transfer.accept.\(resumeMode(for: resumeOffset))")
            LoomLogger.debug(
                .transfer,
                "Accepted Loom transfer logicalName=\(state.offer.logicalName) resumeOffset=\(resumeOffset)"
            )
            try await sendControlMessage(
                LoomTransferControlMessage(
                    kind: .accept,
                    transferID: id,
                    resumeOffset: resumeOffset
                )
            )
            await attachPendingDataStream(to: id)
        } catch {
            if let failedState = incomingTransfersByID.removeValue(forKey: id) {
                failedState.completionDeadlineTask?.cancel()
                failedState.task?.cancel()
                try? await failedState.sink?.close()
                failedState.handle.yield(
                    progress(
                        for: failedState.offer,
                        bytesTransferred: failedState.bytesReceived,
                        state: .failed
                    )
                )
                try? await sendControlMessage(
                    LoomTransferControlMessage(kind: .cancel, transferID: id)
                )
            } else {
                try? await sink.close()
            }
            throw error
        }
    }

    private func declineIncomingTransfer(id: UUID) async throws {
        guard let state = incomingTransfersByID.removeValue(forKey: id) else {
            return
        }
        state.offerDecisionTask?.cancel()
        state.completionDeadlineTask?.cancel()
        state.task?.cancel()
        try? await state.sink?.close()
        recordTransferStep("loom.transfer.declined.local")
        LoomLogger.log(
            .transfer,
            "Declined Loom transfer logicalName=\(state.offer.logicalName)"
        )
        state.handle.yield(progress(for: state.offer, bytesTransferred: 0, state: .declined))
        await discardPendingDataStream(id: id, reason: "transfer-declined")
        try await sendControlMessage(
            LoomTransferControlMessage(
                kind: .decline,
                transferID: id
            )
        )
    }

    private func startOutgoingTransfer(
        id: UUID,
        resumeOffset: UInt64
    ) async throws {
        guard var state = outgoingTransfers[id] else {
            throw LoomTransferError.missingTransferState
        }
        guard !state.isAccepted else {
            throw LoomTransferError.protocolViolation("Outgoing Loom transfer was already accepted.")
        }
        state.offerDecisionTask?.cancel()
        state.offerDecisionTask = nil
        guard resumeOffset <= state.offer.byteLength else {
            outgoingTransfers.removeValue(forKey: id)
            state.completionDeadlineTask?.cancel()
            await scheduler.finishTransfer(id: id)
            state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesTransferred, state: .failed))
            try? await sendControlMessage(
                LoomTransferControlMessage(
                    kind: .cancel,
                    transferID: id
                )
            )
            throw LoomTransferError.protocolViolation(
                "Invalid Loom transfer resume offset \(resumeOffset) for byteLength \(state.offer.byteLength)."
            )
        }
        state.isAccepted = true
        outgoingTransfers[id] = state
        await scheduler.registerTransfer(
            id: id,
            remainingBytes: state.offer.byteLength - resumeOffset
        )
        guard var liveState = outgoingTransfers[id], liveState.isAccepted else {
            await scheduler.finishTransfer(id: id)
            throw LoomTransferError.missingTransferState
        }
        liveState.startedAt = Date()
        let activeTransferTimeout = configuration.activeTransferTimeout
        liveState.completionDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: activeTransferTimeout)
            } catch {
                return
            }
            await self?.expireOutgoingActiveTransfer(id: id)
        }
        outgoingTransfers[id] = liveState
        do {
            let dataStream = try await session.openStream(label: Self.dataStreamLabel(for: id))
            guard var streamingState = outgoingTransfers[id], streamingState.isAccepted else {
                try? await dataStream.close()
                await scheduler.finishTransfer(id: id)
                throw LoomTransferError.missingTransferState
            }
            streamingState.dataStream = dataStream
            streamingState.task = Task { [weak self] in
                await self?.runOutgoingTransfer(id: id, stream: dataStream, resumeOffset: resumeOffset)
            }
            outgoingTransfers[id] = streamingState
            recordTransferStep("loom.transfer.outgoing_start.\(resumeMode(for: resumeOffset))")
            LoomLogger.debug(
                .transfer,
                "Starting outgoing Loom transfer logicalName=\(streamingState.offer.logicalName) resumeOffset=\(resumeOffset)"
            )
        } catch {
            await scheduler.finishTransfer(id: id)
            if let failedState = outgoingTransfers.removeValue(forKey: id) {
                failedState.offerDecisionTask?.cancel()
                failedState.completionDeadlineTask?.cancel()
                failedState.task?.cancel()
                failedState.handle.yield(
                    progress(
                        for: failedState.offer,
                        bytesTransferred: failedState.bytesTransferred,
                        state: .failed
                    )
                )
            }
            throw error
        }
    }

    private func runOutgoingTransfer(
        id: UUID,
        stream: LoomMultiplexedStream,
        resumeOffset: UInt64
    ) async {
        guard var state = outgoingTransfers[id] else {
            return
        }
        state.handle.yield(progress(for: state.offer, bytesTransferred: resumeOffset, state: .transferring))
        state.bytesTransferred = resumeOffset
        outgoingTransfers[id] = state

        do {
            var offset = resumeOffset
            while offset < state.offer.byteLength {
                let remainingBytes = state.offer.byteLength - offset
                let grantedChunkSize = await scheduler.acquireChunk(
                    for: id,
                    remainingBytes: remainingBytes
                )
                if grantedChunkSize == 0 || Task.isCancelled {
                    throw CancellationError()
                }

                let chunk: Data
                do {
                    chunk = try await state.source.read(
                        offset: offset,
                        maxLength: grantedChunkSize
                    )
                } catch {
                    await scheduler.releaseChunk(
                        for: id,
                        bytes: grantedChunkSize,
                        remainingBytes: remainingBytes
                    )
                    throw error
                }
                if chunk.isEmpty {
                    await scheduler.releaseChunk(
                        for: id,
                        bytes: grantedChunkSize,
                        remainingBytes: remainingBytes
                    )
                    throw LoomTransferError.protocolViolation("Transfer source ended before the advertised byte length.")
                }
                guard chunk.count <= grantedChunkSize,
                      UInt64(chunk.count) <= remainingBytes else {
                    await scheduler.releaseChunk(
                        for: id,
                        bytes: grantedChunkSize,
                        remainingBytes: remainingBytes
                    )
                    throw LoomTransferError.protocolViolation(
                        "Transfer source returned more bytes than the granted or advertised range."
                    )
                }
                if chunk.count < grantedChunkSize {
                    await scheduler.releaseChunk(
                        for: id,
                        bytes: grantedChunkSize - chunk.count,
                        remainingBytes: remainingBytes
                    )
                }
                do {
                    try await stream.send(chunk)
                    offset += UInt64(chunk.count)
                    await scheduler.releaseChunk(
                        for: id,
                        bytes: chunk.count,
                        remainingBytes: state.offer.byteLength - offset
                    )
                    if var liveState = outgoingTransfers[id] {
                        liveState.bytesTransferred = offset
                        outgoingTransfers[id] = liveState
                        liveState.handle.yield(progress(for: liveState.offer, bytesTransferred: offset, state: .transferring))
                    }
                    await Task.yield()
                } catch {
                    await scheduler.releaseChunk(
                        for: id,
                        bytes: chunk.count,
                        remainingBytes: remainingBytes
                    )
                    throw error
                }
            }
            try await sendControlMessage(
                LoomTransferControlMessage(
                    kind: .complete,
                    transferID: id,
                    sha256Hex: state.offer.sha256Hex
                )
            )
            try await stream.close()
            guard let finalState = outgoingTransfers.removeValue(forKey: id) else {
                await scheduler.finishTransfer(id: id)
                return
            }
            finalState.offerDecisionTask?.cancel()
            finalState.completionDeadlineTask?.cancel()
            finalState.handle.yield(progress(for: state.offer, bytesTransferred: state.offer.byteLength, state: .completed))
            await scheduler.finishTransfer(id: id)
            LoomInstrumentation.record("loom.transfer.outgoing_complete")
            recordTransferStep("loom.transfer.complete.outgoing.\(resumeMode(for: resumeOffset))")
            LoomLogger.log(
                .transfer,
                completionMessage(
                    direction: "outgoing",
                    offer: state.offer,
                    resumeOffset: resumeOffset,
                    startedAt: state.startedAt,
                    bytesTransferred: state.offer.byteLength
                )
            )
        } catch is CancellationError {
            await scheduler.finishTransfer(id: id)
            try? await stream.close()
            if let cancelledState = outgoingTransfers.removeValue(forKey: id) {
                cancelledState.offerDecisionTask?.cancel()
                cancelledState.completionDeadlineTask?.cancel()
                recordTransferStep("loom.transfer.cancel.local.outgoing")
                LoomLogger.log(
                    .transfer,
                    "Cancelled outgoing Loom transfer logicalName=\(cancelledState.offer.logicalName) bytesTransferred=\(cancelledState.bytesTransferred)"
                )
                cancelledState.handle.yield(
                    progress(
                        for: cancelledState.offer,
                        bytesTransferred: cancelledState.bytesTransferred,
                        state: .cancelled
                    )
                )
            }
        } catch {
            await scheduler.finishTransfer(id: id)
            try? await stream.close()
            if let failedState = outgoingTransfers.removeValue(forKey: id) {
                failedState.offerDecisionTask?.cancel()
                failedState.completionDeadlineTask?.cancel()
                failedState.handle.yield(progress(for: failedState.offer, bytesTransferred: failedState.bytesTransferred, state: .failed))
            }
            LoomDiagnostics.report(
                error: error,
                category: .transfer,
                message: "Outgoing Loom transfer failed: \(error.localizedDescription)"
            )
        }
    }

    private func attachPendingDataStream(to id: UUID) async {
        guard var state = incomingTransfersByID[id],
              state.isAccepted,
              state.task == nil,
              let pendingDataStream = pendingDataStreams.removeValue(forKey: id) else {
            return
        }
        pendingDataStream.expirationTask.cancel()
        state.task = Task { [weak self] in
            await self?.consumeIncomingTransfer(id: id, stream: pendingDataStream.stream)
        }
        incomingTransfersByID[id] = state
    }

    private func discardPendingDataStream(id: UUID, reason: String) async {
        guard let pendingDataStream = pendingDataStreams.removeValue(forKey: id) else { return }
        pendingDataStream.expirationTask.cancel()
        try? await pendingDataStream.stream.close()
        LoomLogger.log(
            .transfer,
            "Discarded pending Loom transfer data stream id=\(id.uuidString) reason=\(reason)"
        )
    }

    private func consumeIncomingTransfer(
        id: UUID,
        stream: LoomMultiplexedStream
    ) async {
        guard let state = incomingTransfersByID[id],
              let sink = state.sink else {
            return
        }
        state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesReceived, state: .transferring))
        incomingTransfersByID[id] = state

        do {
            var offset = state.resumeOffset
            var hasher = state.receivedHasher
            for await payload in stream.incomingBytes {
                let nextOffset = try Self.validatedIncomingOffset(
                    offset: offset,
                    payloadCount: payload.count,
                    offerByteLength: state.offer.byteLength
                )
                try await sink.write(payload, at: offset)
                offset = nextOffset
                if hasher != nil {
                    hasher?.update(data: payload)
                }
                if var liveState = incomingTransfersByID[id] {
                    liveState.bytesReceived = offset
                    liveState.receivedHasher = hasher
                    incomingTransfersByID[id] = liveState
                    liveState.handle.yield(progress(for: liveState.offer, bytesTransferred: offset, state: .transferring))
                }
                await Task.yield()
            }
            if var finishedState = incomingTransfersByID[id] {
                finishedState.isDataComplete = true
                finishedState.bytesReceived = offset
                finishedState.receivedHasher = hasher
                incomingTransfersByID[id] = finishedState
            }
            try await finalizeIncomingTransferIfPossible(id: id)
        } catch {
            if let failedState = incomingTransfersByID.removeValue(forKey: id) {
                failedState.offerDecisionTask?.cancel()
                failedState.completionDeadlineTask?.cancel()
                failedState.task?.cancel()
                try? await failedState.sink?.close()
                failedState.handle.yield(progress(for: failedState.offer, bytesTransferred: failedState.bytesReceived, state: .failed))
            }
            try? await stream.close()
            LoomDiagnostics.report(
                error: error,
                category: .transfer,
                message: "Incoming Loom transfer failed: \(error.localizedDescription)"
            )
        }
    }

    private func finalizeIncomingTransferIfPossible(id: UUID) async throws {
        guard let state = incomingTransfersByID[id],
              state.isDataComplete,
              state.isControlComplete,
              let sink = state.sink else {
            return
        }
        incomingTransfersByID.removeValue(forKey: id)
        state.offerDecisionTask?.cancel()
        state.completionDeadlineTask?.cancel()

        do {
            if state.bytesReceived != state.offer.byteLength {
                throw LoomTransferError.protocolViolation("Received Loom transfer byte count did not match the offer length.")
            }
            if state.resumeOffset == 0,
               let expectedSHA = state.expectedSHA256Hex,
               let hasher = state.receivedHasher {
                let digest = hasher.finalize().hexLowercased
                guard digest == expectedSHA.lowercased() else {
                    recordTransferStep("loom.transfer.integrity_mismatch")
                    LoomLogger.error(
                        .transfer,
                        error: LoomTransferError.integrityMismatch,
                        message: "Incoming Loom transfer integrity mismatch logicalName=\(state.offer.logicalName) bytesTransferred=\(state.bytesReceived)"
                    )
                    throw LoomTransferError.integrityMismatch
                }
            }
            try await sink.finalize(
                offer: state.offer,
                bytesWritten: state.bytesReceived
            )
            try await sink.close()
            state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesReceived, state: .completed))
            LoomInstrumentation.record("loom.transfer.incoming_complete")
            recordTransferStep("loom.transfer.complete.incoming.\(resumeMode(for: state.resumeOffset))")
            LoomLogger.log(
                .transfer,
                completionMessage(
                    direction: "incoming",
                    offer: state.offer,
                    resumeOffset: state.resumeOffset,
                    startedAt: state.acceptedAt,
                    bytesTransferred: state.bytesReceived
                )
            )
        } catch {
            try? await sink.close()
            state.handle.yield(
                progress(
                    for: state.offer,
                    bytesTransferred: state.bytesReceived,
                    state: .failed
                )
            )
            throw error
        }
    }

    private func cancelOutgoingTransfer(id: UUID) async {
        guard let state = outgoingTransfers.removeValue(forKey: id) else {
            return
        }
        state.offerDecisionTask?.cancel()
        state.completionDeadlineTask?.cancel()
        await scheduler.finishTransfer(id: id)
        recordTransferStep("loom.transfer.cancel.local.outgoing")
        LoomLogger.log(
            .transfer,
            "Cancelled outgoing Loom transfer logicalName=\(state.offer.logicalName) bytesTransferred=\(state.bytesTransferred)"
        )
        state.task?.cancel()
        try? await state.dataStream?.close()
        state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesTransferred, state: .cancelled))
        do {
            try await sendControlMessage(
                LoomTransferControlMessage(
                    kind: .cancel,
                    transferID: id
                )
            )
        } catch {}
    }

    private func expireOutgoingOfferDecision(id: UUID) async {
        guard let state = outgoingTransfers[id],
              state.task == nil,
              state.completionDeadlineTask == nil else {
            return
        }
        outgoingTransfers.removeValue(forKey: id)
        state.handle.yield(
            progress(
                for: state.offer,
                bytesTransferred: state.bytesTransferred,
                state: .failed
            )
        )
        try? await sendControlMessage(
            LoomTransferControlMessage(kind: .cancel, transferID: id)
        )
    }

    private func expireIncomingOfferDecision(id: UUID) async {
        guard let state = incomingTransfersByID[id], !state.isAccepted else {
            return
        }
        incomingTransfersByID.removeValue(forKey: id)
        state.handle.yield(
            progress(
                for: state.offer,
                bytesTransferred: state.bytesReceived,
                state: .declined
            )
        )
        await discardPendingDataStream(id: id, reason: "offer-decision-timeout")
        try? await sendControlMessage(
            LoomTransferControlMessage(kind: .decline, transferID: id)
        )
    }

    private func expireOutgoingActiveTransfer(id: UUID) async {
        guard let state = outgoingTransfers.removeValue(forKey: id) else {
            return
        }
        state.offerDecisionTask?.cancel()
        state.task?.cancel()
        await scheduler.finishTransfer(id: id)
        try? await state.dataStream?.close()
        state.handle.yield(
            progress(
                for: state.offer,
                bytesTransferred: state.bytesTransferred,
                state: .failed
            )
        )
        try? await sendControlMessage(
            LoomTransferControlMessage(kind: .cancel, transferID: id)
        )
    }

    private func expireIncomingActiveTransfer(id: UUID) async {
        guard let state = incomingTransfersByID[id], state.isAccepted else {
            return
        }
        incomingTransfersByID.removeValue(forKey: id)
        state.offerDecisionTask?.cancel()
        state.task?.cancel()
        try? await state.sink?.close()
        state.handle.yield(
            progress(
                for: state.offer,
                bytesTransferred: state.bytesReceived,
                state: .failed
            )
        )
        await discardPendingDataStream(id: id, reason: "active-transfer-timeout")
        try? await sendControlMessage(
            LoomTransferControlMessage(kind: .cancel, transferID: id)
        )
    }

    private func validate(offer: LoomTransferOffer) throws {
        guard offer.byteLength <= configuration.maxOfferByteLength else {
            throw LoomTransferError.protocolViolation("Loom transfer offer exceeds the configured object size limit.")
        }
        guard offer.logicalName.lengthOfBytes(using: .utf8) <= configuration.maxOfferLogicalNameBytes else {
            throw LoomTransferError.protocolViolation("Loom transfer logical name exceeds the configured limit.")
        }
        if let contentType = offer.contentType {
            guard contentType.lengthOfBytes(using: .utf8) <= configuration.maxOfferContentTypeBytes else {
                throw LoomTransferError.protocolViolation("Loom transfer content type exceeds the configured limit.")
            }
        }
        guard offer.metadata.count <= configuration.maxOfferMetadataEntries else {
            throw LoomTransferError.protocolViolation("Loom transfer metadata contains too many entries.")
        }
        var metadataBytes = 0
        for (key, value) in offer.metadata {
            let entryBytes = key.lengthOfBytes(using: .utf8) + value.lengthOfBytes(using: .utf8)
            guard entryBytes <= configuration.maxOfferMetadataBytes - metadataBytes else {
                throw LoomTransferError.protocolViolation("Loom transfer metadata exceeds the configured byte limit.")
            }
            metadataBytes += entryBytes
        }
        if let sha256Hex = offer.sha256Hex {
            guard sha256Hex.utf8.count == 64,
                  sha256Hex.utf8.allSatisfy({ byte in
                      (48 ... 57).contains(byte) || (97 ... 102).contains(byte) || (65 ... 70).contains(byte)
                  }) else {
                throw LoomTransferError.protocolViolation("Loom transfer SHA-256 digest is malformed.")
            }
        }
    }

    private func validateControlPayloadSize(_ payload: Data) throws {
        guard payload.count <= configuration.maxControlMessageBytes else {
            throw LoomTransferError.protocolViolation(
                "Transfer control message exceeds the configured encoded byte limit."
            )
        }
    }

    func validateControlPayloadSizeForTesting(_ payload: Data) throws {
        try validateControlPayloadSize(payload)
    }

    func startOutgoingTransferForTesting(id: UUID, resumeOffset: UInt64) async throws {
        try await startOutgoingTransfer(id: id, resumeOffset: resumeOffset)
    }

    static func validatedIncomingOffset(
        offset: UInt64,
        payloadCount: Int,
        offerByteLength: UInt64
    ) throws -> UInt64 {
        guard payloadCount > 0 else {
            throw LoomTransferError.protocolViolation("Incoming Loom transfer payload must not be empty.")
        }
        guard offset <= offerByteLength else {
            throw LoomTransferError.protocolViolation("Incoming Loom transfer offset exceeds the offer length.")
        }
        let (nextOffset, overflowed) = offset.addingReportingOverflow(UInt64(payloadCount))
        guard !overflowed, nextOffset <= offerByteLength else {
            throw LoomTransferError.protocolViolation(
                "Incoming Loom transfer payload exceeds the advertised byte length."
            )
        }
        return nextOffset
    }

    private func progress(
        for offer: LoomTransferOffer,
        bytesTransferred: UInt64,
        state: LoomTransferState
    ) -> LoomTransferProgress {
        LoomTransferProgress(
            transferID: offer.id,
            logicalName: offer.logicalName,
            bytesTransferred: bytesTransferred,
            totalBytes: offer.byteLength,
            state: state
        )
    }

    private static let controlStreamLabel = "loom.transfer.control.v1"
    private static let dataStreamPrefix = "loom.transfer.data."

    private static func dataStreamLabel(for transferID: UUID) -> String {
        "\(dataStreamPrefix)\(transferID.uuidString.lowercased())"
    }

    private static func transferID(fromDataStreamLabel label: String) -> UUID? {
        guard label.hasPrefix(dataStreamPrefix) else {
            return nil
        }
        let suffix = String(label.dropFirst(dataStreamPrefix.count))
        return UUID(uuidString: suffix)
    }

    private func recordTransferStep(_ rawValue: String) {
        LoomInstrumentation.record(LoomStepEvent(rawValue: rawValue))
    }

    private func resumeMode(for offset: UInt64) -> String {
        offset > 0 ? "resumed" : "fresh"
    }

    private func completionMessage(
        direction: String,
        offer: LoomTransferOffer,
        resumeOffset: UInt64,
        startedAt: Date?,
        bytesTransferred: UInt64
    ) -> String {
        let resumedBytes = bytesTransferred - min(bytesTransferred, resumeOffset)
        let bytesPerSecond = transferRateBytesPerSecond(
            startedAt: startedAt,
            transferredBytes: resumedBytes
        )

        return "Completed \(direction) Loom transfer logicalName=\(offer.logicalName) bytes=\(offer.byteLength) resumeOffset=\(resumeOffset) transferredBytes=\(resumedBytes) bytesPerSecond=\(bytesPerSecond)"
    }

    private func transferRateBytesPerSecond(
        startedAt: Date?,
        transferredBytes: UInt64
    ) -> Int {
        guard let startedAt else {
            return 0
        }
        let duration = Date().timeIntervalSince(startedAt)
        guard duration > 0 else {
            return Int(transferredBytes)
        }
        return Int(Double(transferredBytes) / duration)
    }
}

private struct OutgoingTransferState {
    let offer: LoomTransferOffer
    let source: any LoomTransferSource
    let handle: LoomOutgoingTransfer
    var offerDecisionTask: Task<Void, Never>?
    var completionDeadlineTask: Task<Void, Never>?
    var dataStream: LoomMultiplexedStream?
    var task: Task<Void, Never>?
    var bytesTransferred: UInt64 = 0
    var startedAt: Date?
    var isAccepted = false
}

private struct IncomingTransferState {
    let offer: LoomTransferOffer
    let handle: LoomIncomingTransfer
    var offerDecisionTask: Task<Void, Never>?
    var completionDeadlineTask: Task<Void, Never>?
    var sink: (any LoomTransferSink)?
    var task: Task<Void, Never>?
    var resumeOffset: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var receivedHasher: SHA256?
    var isAccepted = false
    var isDataComplete = false
    var isControlComplete = false
    var expectedSHA256Hex: String?
    var acceptedAt: Date?
}

private enum LoomTransferControlMessageKind: String, Codable {
    case offer
    case accept
    case decline
    case cancel
    case complete
}

private struct LoomTransferControlMessage: Codable, Sendable {
    let kind: LoomTransferControlMessageKind
    let transferID: UUID?
    let offer: LoomTransferOffer?
    let resumeOffset: UInt64?
    let sha256Hex: String?

    init(
        kind: LoomTransferControlMessageKind,
        transferID: UUID? = nil,
        offer: LoomTransferOffer? = nil,
        resumeOffset: UInt64? = nil,
        sha256Hex: String? = nil
    ) {
        self.kind = kind
        self.transferID = transferID
        self.offer = offer
        self.resumeOffset = resumeOffset
        self.sha256Hex = sha256Hex
    }
}

private extension SHA256Digest {
    var hexLowercased: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
