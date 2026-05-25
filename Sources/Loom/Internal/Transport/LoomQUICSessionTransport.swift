//
//  LoomQUICSessionTransport.swift
//  Loom
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Dispatch
import Foundation
import Network

package actor LoomQUICSessionTransport: LoomSessionTransport {
    package let receiveSemantics: LoomSessionReceiveSemantics = .independentReliableAndUnreliable

    private let connection: NetworkConnection<QUIC>
    private let role: LoomSessionRole
    private var controlStream: QUIC.Stream<TLV>?
    private var datagrams: QUIC.Datagrams<QUICDatagram>?
    private var queuedUnreliableSenders: [LoomQueuedUnreliableSendProfile: LoomOrderedUnreliableSendQueue] = [:]
    private var inboundStreamTask: Task<Void, Never>?
    private var datagramReceiveTask: Task<Void, Never>?
    private var observationHandler: (@Sendable (LoomSessionTransportObservation) -> Void)?
    private var isClosed = false

    private let unreliableDeliveryStream: AsyncStream<Data>
    private var unreliableDeliveryContinuation: AsyncStream<Data>.Continuation?
    private let priorityUnreliableDeliveryStream: AsyncStream<Data>
    private var priorityUnreliableDeliveryContinuation: AsyncStream<Data>.Continuation?

    package init(
        connection: NetworkConnection<QUIC>,
        role: LoomSessionRole
    ) {
        self.connection = connection
        self.role = role
        let (unreliableStream, unreliableContinuation) = AsyncStream.makeStream(of: Data.self)
        unreliableDeliveryStream = unreliableStream
        unreliableDeliveryContinuation = unreliableContinuation
        let (priorityStream, priorityContinuation) = AsyncStream.makeStream(of: Data.self)
        priorityUnreliableDeliveryStream = priorityStream
        priorityUnreliableDeliveryContinuation = priorityContinuation
    }

    deinit {
        inboundStreamTask?.cancel()
        datagramReceiveTask?.cancel()
        unreliableDeliveryContinuation?.finish()
        priorityUnreliableDeliveryContinuation?.finish()
        for sender in queuedUnreliableSenders.values {
            sender.close()
        }
    }

    package func startAndAwaitReady(queue: DispatchQueue) async throws {
        LoomLogger.transport(
            "QUIC session transport starting role=\(role.rawValue) endpoint=\(connection.remoteEndpoint?.debugDescription ?? "unknown") state=\(connection.state)"
        )
        switch role {
        case .initiator:
            try await awaitConnectionReady()
            LoomLogger.transport("QUIC initiator connection ready; control stream will open on first send")
        case .receiver:
            _ = connection.start()
            LoomLogger.transport("QUIC receiver connection started; waiting for initial control stream")
            controlStream = try await receiveInitialInboundStream()
            LoomLogger.transport("QUIC receiver accepted initial control stream")
        }
        if let controlStream {
            try await awaitControlStreamReady(controlStream)
            LoomLogger.transport("QUIC control stream ready role=\(role.rawValue)")
        }
        LoomLogger.transport(
            "QUIC session transport ready role=\(role.rawValue) endpoint=\(connection.remoteEndpoint?.debugDescription ?? "unknown") connection=\(connection.state) datagramSize=\(connection.usableDatagramFrameSize)"
        )
    }

    package func sendMessage(_ data: Data) async throws {
        try await sendFrame(data)
    }

    package func receiveMessage(maxBytes: Int) async throws -> Data {
        try await readFrame(maxBytes: maxBytes)
    }

    package func sendHandshakeMessage(_ data: Data) async throws {
        try await sendMessage(data)
    }

    package func receiveHandshakeMessage(maxBytes: Int) async throws -> Data {
        try await receiveMessage(maxBytes: maxBytes)
    }

    package func sendUnreliable(_ data: Data) async throws {
        let datagrams = try await ensureDatagramsReady()
        try await datagrams.send(data)
    }

    package func sendUnreliableQueued(
        _ data: Data,
        profile: LoomQueuedUnreliableSendProfile,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) async {
        let datagrams: QUIC.Datagrams<QUICDatagram>
        do {
            datagrams = try await ensureDatagramsReady()
        } catch {
            onComplete(error)
            return
        }

        queuedUnreliableSender(for: profile, datagrams: datagrams).enqueue(data) { error in
            if let error {
                onComplete(LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
            } else {
                onComplete(nil)
            }
        }
    }

    package func resetQueuedUnreliableSends(
        profile: LoomQueuedUnreliableSendProfile
    ) async {
        queuedUnreliableSenders.removeValue(forKey: profile)?.close()
    }

    package func receiveUnreliable(maxBytes: Int) async throws -> Data {
        _ = try await ensureDatagramsReady()
        startDatagramReceiveLoop()
        for await message in unreliableDeliveryStream {
            if message.count > maxBytes {
                throw LoomError.protocolError("Received QUIC datagram exceeds limit: \(message.count) > \(maxBytes)")
            }
            return message
        }
        throw LoomError.connectionFailed(
            LoomConnectionFailure(reason: .cancelled, detail: "QUIC datagram receive cancelled.")
        )
    }

    package func prepareUnreliableReceive(maxBytes: Int) async throws {
        _ = try await ensureDatagramsReady()
        startDatagramReceiveLoop()
    }

    package func receivePriorityUnreliable(maxBytes: Int) async throws -> Data {
        _ = try await ensureDatagramsReady()
        startDatagramReceiveLoop()
        for await message in priorityUnreliableDeliveryStream {
            if message.count > maxBytes {
                throw LoomError.protocolError("Received QUIC priority datagram exceeds limit: \(message.count) > \(maxBytes)")
            }
            return message
        }
        throw LoomError.connectionFailed(
            LoomConnectionFailure(reason: .cancelled, detail: "QUIC priority datagram receive cancelled.")
        )
    }

    package func cancelPendingUnreliableSends() async {
        for sender in queuedUnreliableSenders.values {
            sender.close()
        }
    }

    package func closeTransport() async {
        isClosed = true
        inboundStreamTask?.cancel()
        datagramReceiveTask?.cancel()
        await cancelPendingUnreliableSends()
        unreliableDeliveryContinuation?.finish()
        priorityUnreliableDeliveryContinuation?.finish()
    }

    package func setObservationHandler(
        _ handler: (@Sendable (LoomSessionTransportObservation) -> Void)?
    ) async {
        observationHandler = handler
        if let snapshot = connection.currentPath.map(LoomSessionNetworkPathSnapshot.init(path:)) {
            handler?(.path(snapshot))
        }
    }

    private func awaitConnectionReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = LoomQUICReadyContinuationBox(continuation: continuation)
            let handleState: @Sendable (NetworkChannel<QUIC>.State) -> Void = { [weak self] state in
                if let self {
                    Task {
                        await self.handleConnectionStateUpdate(state)
                    }
                }
                switch state {
                case .ready:
                    box.complete(.success(()))
                case let .failed(error):
                    box.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                case .cancelled:
                    box.complete(
                        .failure(
                            LoomError.connectionFailed(
                                LoomConnectionFailure(reason: .cancelled, detail: "QUIC connection cancelled.")
                            )
                        )
                    )
                case let .waiting(error):
                    LoomLogger.transport("QUIC connection waiting: \(error)")
                    if LoomFramedConnection.shouldFailAfterWaiting(error) {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            box.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                        }
                    }
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.onStateUpdate { _, state in
                handleState(state)
            }
            handleState(connection.state)
            _ = connection.start()
        }
    }

    private func handleConnectionStateUpdate(_ state: NetworkChannel<QUIC>.State) {
        if let snapshot = connection.currentPath.map(LoomSessionNetworkPathSnapshot.init(path:)) {
            observationHandler?(.path(snapshot))
        }

        switch state {
        case let .failed(error):
            observationHandler?(.failed(error.localizedDescription))
        case .cancelled:
            observationHandler?(.cancelled)
        default:
            break
        }
    }

    private func receiveInitialInboundStream() async throws -> QUIC.Stream<TLV> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: QUIC.Stream<TLV>.self)
        inboundStreamTask = Task { [connection] in
            do {
                try await connection.inboundStreams(prepending: { quicStream in
                    TLV { quicStream }
                }) { inboundStream in
                    LoomLogger.debug(
                        .transport,
                        "QUIC inbound stream yielded state=\(inboundStream.state)"
                    )
                    continuation.yield(inboundStream)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: LoomError.connectionFailed(LoomConnectionFailure.classify(error)))
            }
        }

        var iterator = stream.makeAsyncIterator()
        guard let inboundStream = try await iterator.next() else {
            throw LoomError.connectionFailed(
                LoomConnectionFailure(reason: .closed, detail: "QUIC connection closed before opening a control stream.")
            )
        }
        return inboundStream
    }

    private func awaitControlStreamReady(_ stream: QUIC.Stream<TLV>) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + 2.0
        while true {
            switch stream.state {
            case .ready:
                return
            case let .failed(error):
                throw LoomError.connectionFailed(LoomConnectionFailure.classify(error))
            case .cancelled:
                throw LoomError.connectionFailed(
                    LoomConnectionFailure(reason: .cancelled, detail: "QUIC control stream cancelled.")
                )
            case let .waiting(error):
                LoomLogger.transport("QUIC control stream waiting: \(error)")
                if LoomFramedConnection.shouldFailAfterWaiting(error),
                   CFAbsoluteTimeGetCurrent() >= deadline {
                    throw LoomError.connectionFailed(LoomConnectionFailure.classify(error))
                }
            case .setup, .preparing:
                if CFAbsoluteTimeGetCurrent() >= deadline {
                    throw LoomError.connectionFailed(
                        LoomConnectionFailure(
                            reason: .timedOut,
                            detail: "QUIC control stream did not become ready."
                        )
                    )
                }
            @unknown default:
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func startDatagramReceiveLoop() {
        guard datagramReceiveTask == nil, let datagrams else { return }
        datagramReceiveTask = Task { [weak self, datagrams] in
            while !Task.isCancelled {
                do {
                    let message = try await datagrams.receive()
                    await self?.handleIncomingDatagram(message.content)
                } catch {
                    if !Task.isCancelled {
                        await self?.finishDatagramStreams()
                    }
                    break
                }
            }
        }
    }

    private func handleIncomingDatagram(_ data: Data) {
        guard !isClosed else { return }
        if data.first == LoomSessionTrafficClass.priorityInput.rawValue {
            priorityUnreliableDeliveryContinuation?.yield(data)
        } else {
            unreliableDeliveryContinuation?.yield(data)
        }
    }

    private func finishDatagramStreams() {
        unreliableDeliveryContinuation?.finish()
        priorityUnreliableDeliveryContinuation?.finish()
    }

    private func ensureDatagramsReady() async throws -> QUIC.Datagrams<QUICDatagram> {
        if let datagrams {
            return datagrams
        }
        let datagrams = try await connection.datagrams
        self.datagrams = datagrams
        LoomLogger.transport(
            "QUIC datagram flow ready role=\(role.rawValue) state=\(datagrams.state) usableSize=\(connection.usableDatagramFrameSize)"
        )
        return datagrams
    }

    private func queuedUnreliableSender(
        for profile: LoomQueuedUnreliableSendProfile,
        datagrams: QUIC.Datagrams<QUICDatagram>
    ) -> LoomOrderedUnreliableSendQueue {
        if let existing = queuedUnreliableSenders[profile] {
            return existing
        }

        let limits = LoomOrderedUnreliableSendQueue.limits(for: profile)
        let sender = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(
                label: "loom.quic.datagram.send.\(profile.rawValue)",
                qos: .userInteractive
            ),
            maxOutstandingPackets: limits.maxOutstandingPackets,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            maxQueuedPackets: limits.maxQueuedPackets,
            replacesQueuedSends: limits.replacesQueuedSends,
            diagnosticsLabel: "quic.\(profile.rawValue)"
        ) { data, onComplete in
            Task {
                do {
                    try await datagrams.send(data)
                    onComplete(nil)
                } catch {
                    onComplete((error as? NWError) ?? .posix(.EIO))
                }
            }
        }
        queuedUnreliableSenders[profile] = sender
        return sender
    }

    private func sendFrame(_ data: Data) async throws {
        let controlStream = try await writableControlStream()
        LoomLogger.debug(
            .transport,
            "QUIC control stream send begin bytes=\(data.count) connection=\(connection.state) stream=\(controlStream.state)"
        )
        for attempt in 0 ..< 5 {
            do {
                try await controlStream.send(data, type: 0)
                LoomLogger.debug(.transport, "QUIC control stream send completed bytes=\(data.count)")
                return
            } catch where Self.isTransientNotConnected(error) && attempt < 4 {
                try await Task.sleep(for: .milliseconds(25 * (attempt + 1)))
            } catch {
                throw LoomError.connectionFailed(
                    LoomConnectionFailure(
                        reason: .transportLoss,
                        detail: "QUIC control stream send failed with connection=\(connection.state) stream=\(controlStream.state): \(error.localizedDescription)"
                    )
                )
            }
        }
        do {
            try await controlStream.send(data, type: 0)
        } catch {
            throw LoomError.connectionFailed(
                LoomConnectionFailure(
                    reason: .transportLoss,
                    detail: "QUIC control stream send failed after retry with connection=\(connection.state) stream=\(controlStream.state): \(error.localizedDescription)"
                )
            )
        }
    }

    private func writableControlStream() async throws -> QUIC.Stream<TLV> {
        if let controlStream {
            return controlStream
        }
        guard role == .initiator else {
            throw LoomError.protocolError("QUIC control stream is not ready.")
        }
        LoomLogger.transport("QUIC initiator opening control stream for first send")
        let stream = try await connection.openStream(directionality: .bidirectional) { quicStream in
            TLV { quicStream }
        }
        controlStream = stream
        return stream
    }

    private func readFrame(maxBytes: Int) async throws -> Data {
        guard let controlStream else {
            throw LoomError.protocolError("QUIC control stream is not ready.")
        }
        let message = try await controlStream.receive()
        guard message.content.count <= maxBytes else {
            throw LoomError.protocolError("Received QUIC frame larger than \(maxBytes) bytes.")
        }
        return message.content
    }

    private static func isTransientNotConnected(_ error: Error) -> Bool {
        LoomConnectionFailure.classify(error).posixCode == .ENOTCONN
    }
}

private final class LoomQUICReadyContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
