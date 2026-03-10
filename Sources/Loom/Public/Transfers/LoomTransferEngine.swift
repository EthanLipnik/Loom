//
//  LoomTransferEngine.swift
//  Loom
//
//  Created by Codex on 3/10/26.
//

import CryptoKit
import Foundation

/// Handle for an app-owned outgoing Loom transfer.
public final class LoomOutgoingTransfer: @unchecked Sendable {
    /// Transfer offer originally sent to the remote peer.
    public let offer: LoomTransferOffer
    /// Async progress stream for the transfer lifecycle.
    public let progressEvents: AsyncStream<LoomTransferProgress>

    private let cancelHandler: @Sendable () async -> Void
    private let progressContinuation: AsyncStream<LoomTransferProgress>.Continuation
    private let progressObservers = LoomAsyncBroadcaster<LoomTransferProgress>()

    fileprivate init(
        offer: LoomTransferOffer,
        cancelHandler: @escaping @Sendable () async -> Void
    ) {
        self.offer = offer
        self.cancelHandler = cancelHandler
        let (stream, continuation) = AsyncStream.makeStream(of: LoomTransferProgress.self)
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
        progressContinuation.yield(progress)
        progressObservers.yield(progress)
        if progress.state == .completed ||
            progress.state == .cancelled ||
            progress.state == .failed ||
            progress.state == .declined {
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
    private let progressObservers = LoomAsyncBroadcaster<LoomTransferProgress>()

    fileprivate init(
        offer: LoomTransferOffer,
        acceptHandler: @escaping @Sendable (any LoomTransferSink, UInt64) async throws -> Void,
        declineHandler: @escaping @Sendable () async throws -> Void
    ) {
        self.offer = offer
        self.acceptHandler = acceptHandler
        self.declineHandler = declineHandler
        let (stream, continuation) = AsyncStream.makeStream(of: LoomTransferProgress.self)
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
        progressContinuation.yield(progress)
        progressObservers.yield(progress)
        if progress.state == .completed ||
            progress.state == .cancelled ||
            progress.state == .failed ||
            progress.state == .declined {
            progressContinuation.finish()
            progressObservers.finish()
        }
    }
}

/// Generic resumable bulk object transfer layered on an authenticated Loom session.
public actor LoomTransferEngine {
    /// Authenticated Loom session used for encrypted control and data streams.
    public let session: LoomAuthenticatedSession
    /// Transfer scheduling configuration used by the engine.
    public let configuration: LoomTransferConfiguration
    /// Async stream of remote transfer offers that arrive on the session.
    public nonisolated let incomingTransfers: AsyncStream<LoomIncomingTransfer>

    private let incomingTransfersContinuation: AsyncStream<LoomIncomingTransfer>.Continuation
    private var outboundControlStream: LoomMultiplexedStream?
    private var controlStreamTask: Task<Void, Never>?
    private var outgoingTransfers: [UUID: OutgoingTransferState] = [:]
    private var incomingTransfersByID: [UUID: IncomingTransferState] = [:]
    private var pendingDataStreams: [UUID: LoomMultiplexedStream] = [:]
    private let scheduler: LoomTransferScheduler

    /// Creates a transfer engine bound to one authenticated Loom session.
    public init(
        session: LoomAuthenticatedSession,
        configuration: LoomTransferConfiguration = .default
    ) {
        self.session = session
        self.configuration = configuration
        scheduler = LoomTransferScheduler(configuration: configuration)
        let (stream, continuation) = AsyncStream.makeStream(of: LoomIncomingTransfer.self)
        incomingTransfers = stream
        incomingTransfersContinuation = continuation
        Task { [weak self] in
            await self?.observeIncomingStreams()
        }
    }

    deinit {
        controlStreamTask?.cancel()
        incomingTransfersContinuation.finish()
    }

    /// Offers one opaque object to the remote peer and returns a progress handle.
    public func offerTransfer(
        _ offer: LoomTransferOffer,
        source: any LoomTransferSource
    ) async throws -> LoomOutgoingTransfer {
        let progressHandle = LoomOutgoingTransfer(offer: offer) { [weak self] in
            await self?.cancelOutgoingTransfer(id: offer.id)
        }
        outgoingTransfers[offer.id] = OutgoingTransferState(
            offer: offer,
            source: source,
            handle: progressHandle
        )
        progressHandle.yield(progress(for: offer, bytesTransferred: 0, state: .offered))
        try await sendControlMessage(
            LoomTransferControlMessage(
                kind: .offer,
                transferID: offer.id,
                offer: offer
            )
        )
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
                controlStreamTask?.cancel()
                controlStreamTask = Task { [weak self] in
                    await self?.consumeControlStream(stream)
                }
                continue
            }
            guard let transferID = Self.transferID(fromDataStreamLabel: label) else {
                continue
            }
            pendingDataStreams[transferID] = stream
            if let incomingState = incomingTransfersByID[transferID],
               incomingState.isAccepted {
                await attachPendingDataStream(to: transferID)
            }
        }
    }

    private func consumeControlStream(_ stream: LoomMultiplexedStream) async {
        for await payload in stream.incomingBytes {
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
    }

    private func handleControlMessage(_ message: LoomTransferControlMessage) async throws {
        switch message.kind {
        case .offer:
            guard let offer = message.offer else {
                throw LoomTransferError.protocolViolation("Missing Loom transfer offer payload.")
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
            incomingTransfersByID[offer.id] = IncomingTransferState(
                offer: offer,
                handle: incoming
            )
            incoming.yield(progress(for: offer, bytesTransferred: 0, state: .offered))
            incomingTransfersContinuation.yield(incoming)
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
            recordTransferStep(
                "loom.transfer.declined.remote.\(resumeMode(for: state.bytesTransferred))"
            )
            LoomLogger.log(
                .transfer,
                "Remote peer declined Loom transfer logicalName=\(state.offer.logicalName) bytesTransferred=\(state.bytesTransferred)"
            )
            state.task?.cancel()
            state.handle.yield(progress(for: state.offer, bytesTransferred: state.bytesTransferred, state: .declined))

        case .cancel:
            guard let transferID = message.transferID else {
                return
            }
            if let outgoing = outgoingTransfers.removeValue(forKey: transferID) {
                await scheduler.finishTransfer(id: transferID)
                recordTransferStep("loom.transfer.cancel.remote.outgoing")
                LoomLogger.log(
                    .transfer,
                    "Remote peer cancelled outgoing Loom transfer logicalName=\(outgoing.offer.logicalName) bytesTransferred=\(outgoing.bytesTransferred)"
                )
                outgoing.task?.cancel()
                outgoing.handle.yield(progress(for: outgoing.offer, bytesTransferred: outgoing.bytesTransferred, state: .cancelled))
            }
            if let incoming = incomingTransfersByID.removeValue(forKey: transferID) {
                recordTransferStep("loom.transfer.cancel.remote.incoming")
                LoomLogger.log(
                    .transfer,
                    "Remote peer cancelled incoming Loom transfer logicalName=\(incoming.offer.logicalName) bytesTransferred=\(incoming.bytesReceived)"
                )
                incoming.task?.cancel()
                incoming.handle.yield(progress(for: incoming.offer, bytesTransferred: incoming.bytesReceived, state: .cancelled))
            }

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
        state.sink = sink
        state.resumeOffset = resumeOffset
        state.bytesReceived = resumeOffset
        state.isAccepted = true
        state.expectedSHA256Hex = state.offer.sha256Hex
        if resumeOffset == 0 {
            state.receivedHasher = SHA256()
        }
        state.acceptedAt = Date()
        incomingTransfersByID[id] = state

        try await sink.truncate(to: resumeOffset)
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
    }

    private func declineIncomingTransfer(id: UUID) async throws {
        guard let state = incomingTransfersByID.removeValue(forKey: id) else {
            return
        }
        recordTransferStep("loom.transfer.declined.local")
        LoomLogger.log(
            .transfer,
            "Declined Loom transfer logicalName=\(state.offer.logicalName)"
        )
        state.handle.yield(progress(for: state.offer, bytesTransferred: 0, state: .declined))
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
        await scheduler.registerTransfer(
            id: id,
            remainingBytes: state.offer.byteLength - resumeOffset
        )
        state.startedAt = Date()
        do {
            let dataStream = try await session.openStream(label: Self.dataStreamLabel(for: id))
            state.task?.cancel()
            state.task = Task { [weak self] in
                await self?.runOutgoingTransfer(id: id, stream: dataStream, resumeOffset: resumeOffset)
            }
            outgoingTransfers[id] = state
            recordTransferStep("loom.transfer.outgoing_start.\(resumeMode(for: resumeOffset))")
            LoomLogger.debug(
                .transfer,
                "Starting outgoing Loom transfer logicalName=\(state.offer.logicalName) resumeOffset=\(resumeOffset)"
            )
        } catch {
            await scheduler.finishTransfer(id: id)
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
            try await stream.close()
            if let finalState = outgoingTransfers[id] {
                finalState.handle.yield(progress(for: finalState.offer, bytesTransferred: finalState.offer.byteLength, state: .completed))
            }
            try await sendControlMessage(
                LoomTransferControlMessage(
                    kind: .complete,
                    transferID: id,
                    sha256Hex: state.offer.sha256Hex
                )
            )
            outgoingTransfers.removeValue(forKey: id)
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
            if let cancelledState = outgoingTransfers.removeValue(forKey: id) {
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
            if let failedState = outgoingTransfers.removeValue(forKey: id) {
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
              let stream = pendingDataStreams.removeValue(forKey: id) else {
            return
        }
        state.task = Task { [weak self] in
            await self?.consumeIncomingTransfer(id: id, stream: stream)
        }
        incomingTransfersByID[id] = state
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
                try await sink.write(payload, at: offset)
                offset += UInt64(payload.count)
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
                failedState.handle.yield(progress(for: failedState.offer, bytesTransferred: failedState.bytesReceived, state: .failed))
            }
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
        incomingTransfersByID.removeValue(forKey: id)
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
    }

    private func cancelOutgoingTransfer(id: UUID) async {
        guard let state = outgoingTransfers.removeValue(forKey: id) else {
            return
        }
        await scheduler.finishTransfer(id: id)
        recordTransferStep("loom.transfer.cancel.local.outgoing")
        LoomLogger.log(
            .transfer,
            "Cancelled outgoing Loom transfer logicalName=\(state.offer.logicalName) bytesTransferred=\(state.bytesTransferred)"
        )
        state.task?.cancel()
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
    var task: Task<Void, Never>?
    var bytesTransferred: UInt64 = 0
    var startedAt: Date?
}

private struct IncomingTransferState {
    let offer: LoomTransferOffer
    let handle: LoomIncomingTransfer
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
