//
//  LoomConnectionHandle.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

import CryptoKit
import Foundation
import Loom

/// Actor-backed app-facing connection handle returned by LoomKit.
public actor LoomConnectionHandle {
    /// Stable LoomKit connection identifier.
    public let id: UUID
    /// Snapshot of the peer this handle is connected to.
    public let peer: LoomPeerSnapshot
    /// Underlying authenticated Loom session for advanced escape-hatch use.
    public let session: LoomAuthenticatedSession
    /// Transfer engine bound to the authenticated session.
    public let transferEngine: LoomTransferEngine

    /// Stream of bytes received on the default LoomKit message stream.
    public nonisolated let messages: AsyncStream<Data>
    /// Stream of high-level connection and transfer events.
    public nonisolated let events: AsyncStream<LoomConnectionEvent>
    /// Stream of offered incoming transfers before acceptance.
    public nonisolated let incomingTransfers: AsyncStream<LoomIncomingTransfer>

    private let messagesContinuation: AsyncStream<Data>.Continuation
    private let eventsContinuation: AsyncStream<LoomConnectionEvent>.Continuation
    private let incomingTransfersContinuation: AsyncStream<LoomIncomingTransfer>.Continuation
    private let onStateChanged: @Sendable (UUID, LoomConnectionSnapshot.State, String?) async -> Void
    private let onTransferChanged: @Sendable (LoomTransferSnapshot) async -> Void
    private let onDisconnected: @Sendable (UUID, String?) async -> Void

    private var defaultMessageStream: LoomMultiplexedStream?
    private var stateObservationTask: Task<Void, Never>?
    private var streamObservationTask: Task<Void, Never>?
    private var transferObservationTask: Task<Void, Never>?
    private var transferProgressTasks: [UUID: Task<Void, Never>] = [:]
    private var transferFileURLs: [UUID: URL] = [:]
    private var didReportDisconnection = false

    init(
        id: UUID,
        peer: LoomPeerSnapshot,
        session: LoomAuthenticatedSession,
        transferConfiguration: LoomTransferConfiguration,
        onStateChanged: @escaping @Sendable (UUID, LoomConnectionSnapshot.State, String?) async -> Void,
        onTransferChanged: @escaping @Sendable (LoomTransferSnapshot) async -> Void,
        onDisconnected: @escaping @Sendable (UUID, String?) async -> Void
    ) {
        self.id = id
        self.peer = peer
        self.session = session
        transferEngine = LoomTransferEngine(
            session: session,
            configuration: transferConfiguration
        )
        self.onStateChanged = onStateChanged
        self.onTransferChanged = onTransferChanged
        self.onDisconnected = onDisconnected

        let (messages, messagesContinuation) = AsyncStream.makeStream(of: Data.self)
        self.messages = messages
        self.messagesContinuation = messagesContinuation

        let (events, eventsContinuation) = AsyncStream.makeStream(of: LoomConnectionEvent.self)
        self.events = events
        self.eventsContinuation = eventsContinuation

        let (incomingTransfers, incomingTransfersContinuation) = AsyncStream.makeStream(of: LoomIncomingTransfer.self)
        self.incomingTransfers = incomingTransfers
        self.incomingTransfersContinuation = incomingTransfersContinuation
    }

    deinit {
        stateObservationTask?.cancel()
        streamObservationTask?.cancel()
        transferObservationTask?.cancel()
        for task in transferProgressTasks.values {
            task.cancel()
        }
        messagesContinuation.finish()
        eventsContinuation.finish()
        incomingTransfersContinuation.finish()
    }

    func startObservers() {
        guard stateObservationTask == nil,
              streamObservationTask == nil,
              transferObservationTask == nil else {
            return
        }

        stateObservationTask = Task {
            await observeState()
        }
        streamObservationTask = Task {
            await observeIncomingStreams()
        }
        transferObservationTask = Task {
            await observeIncomingTransfers()
        }
    }

    /// Sends raw bytes on the default LoomKit message stream.
    public func send(_ data: Data) async throws {
        let stream = try await defaultMessageStreamForSending()
        do {
            try await stream.send(data)
        } catch {
            defaultMessageStream = nil
            throw error
        }
    }

    /// Sends a UTF-8 encoded string on the default LoomKit message stream.
    public func send(_ string: String) async throws {
        try await send(Data(string.utf8))
    }

    /// Encodes and sends a value as JSON on the default LoomKit message stream.
    public func send<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) async throws {
        try await send(encoder.encode(value))
    }

    /// Offers a file-backed transfer to the connected peer.
    public func sendFile(
        at url: URL,
        named: String? = nil,
        contentType: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> LoomOutgoingTransfer {
        let source = try LoomFileTransferSource(url: url)
        let logicalName = Self.logicalName(named, fallback: url.lastPathComponent)
        let offer = LoomTransferOffer(
            logicalName: logicalName,
            byteLength: await source.byteLength,
            contentType: contentType,
            metadata: metadata
        )
        let outgoing = try await transferEngine.offerTransfer(offer, source: source)
        transferFileURLs[offer.id] = url
        observeOutgoingTransfer(outgoing)
        return outgoing
    }

    /// Offers an in-memory data transfer to the connected peer.
    public func sendData(
        _ data: Data,
        named: String,
        contentType: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> LoomOutgoingTransfer {
        let source = LoomDataTransferSource(data: data)
        let offer = LoomTransferOffer(
            logicalName: Self.logicalName(named, fallback: "data"),
            byteLength: source.byteLength,
            contentType: contentType,
            sha256Hex: data.sha256Hex,
            metadata: metadata
        )
        let outgoing = try await transferEngine.offerTransfer(offer, source: source)
        observeOutgoingTransfer(outgoing)
        return outgoing
    }

    /// Accepts an offered incoming transfer into the provided file destination.
    public func accept(
        _ transfer: LoomIncomingTransfer,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws {
        let sink = try LoomFileTransferSink(url: destinationURL)
        transferFileURLs[transfer.offer.id] = destinationURL
        let resumeOffset = if resumeIfPossible {
            Self.resumeOffset(for: destinationURL, totalBytes: transfer.offer.byteLength)
        } else {
            UInt64.zero
        }
        try await transfer.accept(using: sink, resumeOffset: resumeOffset)
    }

    /// Cancels the authenticated session and tears down the connection handle.
    public func disconnect() async {
        eventsContinuation.yield(.stateChanged(.disconnecting))
        await onStateChanged(id, .disconnecting, nil)
        await session.cancel()
    }

    /// Opens an additional custom multiplexed stream beyond the default message stream.
    public func openStream(label: String) async throws -> LoomMultiplexedStream {
        try await session.openStream(label: label)
    }

    private func defaultMessageStreamForSending() async throws -> LoomMultiplexedStream {
        if let defaultMessageStream {
            return defaultMessageStream
        }
        let stream = try await session.openStream(label: Self.defaultMessageStreamLabel)
        defaultMessageStream = stream
        return stream
    }

    private func observeState() async {
        let stateStream = await session.makeStateObserver()
        for await state in stateStream {
            let snapshotState = Self.snapshotState(for: state)
            let errorMessage = Self.errorMessage(for: state)
            eventsContinuation.yield(.stateChanged(snapshotState))
            await onStateChanged(id, snapshotState, errorMessage)
            if snapshotState == .failed || snapshotState == .disconnected {
                await reportDisconnectionIfNeeded(errorMessage)
                finishPublicStreams()
            }
        }
        await reportDisconnectionIfNeeded(nil)
        finishPublicStreams()
    }

    private func observeIncomingStreams() async {
        let streamObserver = session.makeIncomingStreamObserver()
        for await stream in streamObserver {
            guard stream.label == Self.defaultMessageStreamLabel else {
                continue
            }
            for await payload in stream.incomingBytes {
                messagesContinuation.yield(payload)
                eventsContinuation.yield(.message(payload))
            }
        }
    }

    private func observeIncomingTransfers() async {
        for await transfer in transferEngine.incomingTransfers {
            incomingTransfersContinuation.yield(transfer)
            eventsContinuation.yield(.incomingTransfer(transfer))
            observeIncomingTransfer(transfer)
        }
    }

    private func observeIncomingTransfer(_ transfer: LoomIncomingTransfer) {
        let snapshot = transferSnapshot(
            offer: transfer.offer,
            direction: .incoming,
            progress: LoomTransferProgress(
                transferID: transfer.offer.id,
                logicalName: transfer.offer.logicalName,
                bytesTransferred: 0,
                totalBytes: transfer.offer.byteLength,
                state: .offered
            )
        )
        Task {
            await onTransferChanged(snapshot)
        }
        observeProgress(
            for: transfer.offer,
            direction: .incoming,
            progressStream: transfer.makeProgressObserver()
        )
    }

    private func observeOutgoingTransfer(_ transfer: LoomOutgoingTransfer) {
        observeProgress(
            for: transfer.offer,
            direction: .outgoing,
            progressStream: transfer.makeProgressObserver()
        )
    }

    private func observeProgress(
        for offer: LoomTransferOffer,
        direction: LoomTransferSnapshot.Direction,
        progressStream: AsyncStream<LoomTransferProgress>
    ) {
        transferProgressTasks[offer.id]?.cancel()
        transferProgressTasks[offer.id] = Task {
            for await progress in progressStream {
                let snapshot = transferSnapshot(
                    offer: offer,
                    direction: direction,
                    progress: progress
                )
                await onTransferChanged(snapshot)
            }
            finishTransferObservation(for: offer.id)
        }
    }

    private func finishTransferObservation(for transferID: UUID) {
        transferProgressTasks.removeValue(forKey: transferID)
        if transferFileURLs[transferID] == nil {
            return
        }
    }

    private func transferSnapshot(
        offer: LoomTransferOffer,
        direction: LoomTransferSnapshot.Direction,
        progress: LoomTransferProgress
    ) -> LoomTransferSnapshot {
        LoomTransferSnapshot(
            id: offer.id,
            connectionID: id,
            peerID: peer.id,
            logicalName: offer.logicalName,
            direction: direction,
            state: progress.state,
            bytesTransferred: progress.bytesTransferred,
            totalBytes: progress.totalBytes,
            contentType: offer.contentType,
            fileURL: transferFileURLs[offer.id]
        )
    }

    private func reportDisconnectionIfNeeded(_ errorMessage: String?) async {
        guard !didReportDisconnection else {
            return
        }
        didReportDisconnection = true
        eventsContinuation.yield(.disconnected(errorMessage))
        await onDisconnected(id, errorMessage)
    }

    private func finishPublicStreams() {
        messagesContinuation.finish()
        eventsContinuation.finish()
        incomingTransfersContinuation.finish()
    }

    private static func snapshotState(for state: LoomAuthenticatedSessionState) -> LoomConnectionSnapshot.State {
        switch state {
        case .idle,
             .handshaking:
            .connecting
        case .ready:
            .connected
        case .cancelled:
            .disconnected
        case .failed:
            .failed
        }
    }

    private static func errorMessage(for state: LoomAuthenticatedSessionState) -> String? {
        switch state {
        case let .failed(message):
            message
        case .idle,
             .handshaking,
             .ready,
             .cancelled:
            nil
        }
    }

    private static func logicalName(_ proposedName: String?, fallback: String) -> String {
        let trimmedName = proposedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedName?.isEmpty == false ? trimmedName : nil) ?? fallback
    }

    private static func resumeOffset(for destinationURL: URL, totalBytes: UInt64) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            return 0
        }
        return min(fileSize, totalBytes)
    }

    private static let defaultMessageStreamLabel = "loomkit.messages.v1"
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
