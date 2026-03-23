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
    public let negotiatedFeatures: [String]
    public let sessionEncrypted: Bool

    public init(
        peerIdentity: LoomPeerIdentity,
        peerAdvertisement: LoomPeerAdvertisement,
        trustEvaluation: LoomTrustEvaluation,
        transportKind: LoomTransportKind,
        negotiatedFeatures: [String],
        sessionEncrypted: Bool = true
    ) {
        self.peerIdentity = peerIdentity
        self.peerAdvertisement = peerAdvertisement
        self.trustEvaluation = trustEvaluation
        self.transportKind = transportKind
        self.negotiatedFeatures = negotiatedFeatures
        self.sessionEncrypted = sessionEncrypted
    }
}

/// A logical bidirectional stream multiplexed over an authenticated Loom session.
public final class LoomMultiplexedStream: @unchecked Sendable, Hashable {
    public let id: UInt16
    public let label: String?
    public let incomingBytes: AsyncStream<Data>

    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private let sendHandler: @Sendable (Data) async throws -> Void
    private let unreliableSendHandler: @Sendable (Data) async throws -> Void
    private let closeHandler: @Sendable () async throws -> Void

    package init(
        id: UInt16,
        label: String?,
        sendHandler: @escaping @Sendable (Data) async throws -> Void,
        unreliableSendHandler: @escaping @Sendable (Data) async throws -> Void,
        closeHandler: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.label = label
        self.sendHandler = sendHandler
        self.unreliableSendHandler = unreliableSendHandler
        self.closeHandler = closeHandler
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        incomingBytes = stream
        self.continuation = continuation
    }

    public func send(_ data: Data) async throws {
        try await sendHandler(data)
    }

    public func sendUnreliable(_ data: Data) async throws {
        try await unreliableSendHandler(data)
    }

    public func close() async throws {
        try await closeHandler()
        finishInbound()
    }

    public static func == (lhs: LoomMultiplexedStream, rhs: LoomMultiplexedStream) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    package func yield(_ data: Data) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(data)
    }

    package func finishInbound() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
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
    /// Stable authenticated-session identifier for app-owned bookkeeping.
    public nonisolated let id: UUID
    public let rawSession: LoomSession
    public let role: LoomSessionRole
    public let transportKind: LoomTransportKind

    public nonisolated let incomingStreams: AsyncStream<LoomMultiplexedStream>

    public private(set) var state: LoomAuthenticatedSessionState = .idle
    public private(set) var context: LoomAuthenticatedSessionContext?

    /// Called on the initiator (client) when the receiver (host) signals
    /// that trust evaluation is pending manual approval.
    public var onTrustPending: (@Sendable @MainActor () -> Void)?

    /// Sets the trust-pending callback from outside the actor.
    public func setOnTrustPending(_ handler: (@Sendable @MainActor () -> Void)?) {
        onTrustPending = handler
    }

    private let transport: any LoomSessionTransport
    private let incomingStreamContinuation: AsyncStream<LoomMultiplexedStream>.Continuation
    private let incomingStreamObservers = LoomAsyncBroadcaster<LoomMultiplexedStream>()
    private let stateObservers = LoomAsyncBroadcaster<LoomAuthenticatedSessionState>()
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

    public init(
        rawSession: LoomSession,
        role: LoomSessionRole,
        transportKind: LoomTransportKind
    ) {
        id = UUID()
        self.rawSession = rawSession
        self.role = role
        self.transportKind = transportKind
        switch transportKind {
        case .tcp, .quic:
            transport = LoomFramedConnection(connection: rawSession.connection)
        case .udp:
            transport = LoomReliableChannel(connection: rawSession.connection)
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

    /// Returns the latest remote endpoint observed for this session's transport.
    public var remoteEndpoint: NWEndpoint? {
        currentRemoteEndpoint ?? currentPathSnapshot?.remoteEndpoint ?? rawSession.endpoint
    }

    /// Returns the latest transport-path snapshot observed for this session.
    public var pathSnapshot: LoomSessionNetworkPathSnapshot? {
        currentPathSnapshot
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
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) async throws -> LoomAuthenticatedSessionContext {
        guard case .idle = state else {
            if let context {
                return context
            }
            throw LoomError.protocolError("Authenticated Loom session has already started.")
        }

        updateState(.handshaking)
        try await transport.startAndAwaitReady(queue: queue)

        let preparedHello = try await MainActor.run {
            try LoomSessionHelloValidator.makePreparedSignedHello(
                from: localHello,
                identityManager: identityManager
            )
        }
        let helloData = try JSONEncoder().encode(preparedHello.hello)
        try await transport.sendMessage(helloData)

        let remoteHelloData = try await transport.receiveMessage(
            maxBytes: LoomMessageLimits.maxHelloFrameBytes
        )
        let remoteHello = try JSONDecoder().decode(LoomSessionHello.self, from: remoteHelloData)
        let validatedHello = try await helloValidator.validateDetailed(
            remoteHello,
            endpointDescription: rawSession.endpoint.debugDescription
        )
        let peerIdentity = validatedHello.peerIdentity

        let negotiatedFeatures = Array(
            Set(localHello.supportedFeatures).intersection(remoteHello.supportedFeatures)
        )
        .sorted()

        let encryptionNegotiated = negotiatedFeatures.contains("loom.session-encryption.v1")
        switch encryptionPolicy {
        case .required:
            guard encryptionNegotiated else {
                updateState(.failed("missing-session-encryption"))
                rawSession.cancel()
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
        if trustEvaluation.decision == .denied {
            updateState(.failed("denied"))
            rawSession.cancel()
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
            negotiatedFeatures: negotiatedFeatures,
            sessionEncrypted: encryptionNegotiated
        )
        self.context = context
        configureTransportObserversIfNeeded()
        updateState(.ready)
        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
        unreliableReadTask = Task { [weak self] in
            await self?.runUnreliableReadLoop()
        }
        return context
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
                try await handleEnvelope(envelope)
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
                try await handleEnvelope(envelope)
            }
        } catch {
            if case .cancelled = state { return }
            if case .failed = state { return }
        }
    }

    private func handleEnvelope(_ envelope: LoomSessionStreamEnvelope) async throws {
        switch envelope.kind {
        case .open:
            let stream = makeStream(id: envelope.streamID, label: envelope.label)
            streams[envelope.streamID] = stream
            incomingStreamContinuation.yield(stream)
            incomingStreamObservers.yield(stream)
        case .data:
            guard let stream = streams[envelope.streamID], let payload = envelope.payload else {
                throw LoomError.protocolError("Received data for unknown Loom stream \(envelope.streamID).")
            }
            stream.yield(payload)
        case .close:
            guard let stream = streams.removeValue(forKey: envelope.streamID) else {
                return
            }
            stream.finishInbound()
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
        streams.removeValue(forKey: id)
    }

    private func sendEnvelope(
        _ envelope: LoomSessionStreamEnvelope,
        reliable: Bool = true
    ) async throws {
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

        if reliable {
            try await transport.sendMessage(wireFrame)
        } else {
            try await transport.sendUnreliable(wireFrame)
        }
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
            evaluation.decision == .denied ? .denied : .trusted
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

    private func configureTransportObserversIfNeeded() {
        guard !transportObserversConfigured else { return }
        transportObserversConfigured = true
        currentRemoteEndpoint = rawSession.endpoint

        if let path = rawSession.connection.currentPath {
            applyTransportPathSnapshot(LoomSessionNetworkPathSnapshot(path: path))
        }

        rawSession.connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task {
                await self.handleTransportPathUpdate(path)
            }
        }
        rawSession.connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handleUnderlyingConnectionState(state)
            }
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
            stream.finishInbound()
        }
        streams.removeAll(keepingCapacity: false)
        incomingStreamContinuation.finish()
        incomingStreamObservers.finish()
        stateObservers.finish()
        pathObservers.finish()
        if cancelUnderlyingConnection {
            rawSession.cancel()
        }
    }

    package func setNextOutgoingStreamIDForTesting(_ value: UInt16) {
        nextOutgoingStreamID = value
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
