//
//  LoomAuthenticatedSession.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Network

/// Lifecycle state for an authenticated Loom session.
public enum LoomAuthenticatedSessionState: Sendable, Equatable {
    case idle
    case handshaking
    case ready
    case cancelled
    case failed(String)
}

/// Negotiated session metadata produced by the Loom handshake.
public struct LoomAuthenticatedSessionContext: Sendable {
    public let peerIdentity: LoomPeerIdentity
    public let trustEvaluation: LoomTrustEvaluation
    public let transportKind: LoomTransportKind
    public let negotiatedFeatures: [String]

    public init(
        peerIdentity: LoomPeerIdentity,
        trustEvaluation: LoomTrustEvaluation,
        transportKind: LoomTransportKind,
        negotiatedFeatures: [String]
    ) {
        self.peerIdentity = peerIdentity
        self.trustEvaluation = trustEvaluation
        self.transportKind = transportKind
        self.negotiatedFeatures = negotiatedFeatures
    }
}

/// A logical bidirectional stream multiplexed over an authenticated Loom session.
public final class LoomMultiplexedStream: @unchecked Sendable, Hashable {
    public let id: UInt16
    public let label: String?
    public let incomingBytes: AsyncStream<Data>

    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private let sendHandler: @Sendable (LoomSessionStreamEnvelope) async throws -> Void

    fileprivate init(
        id: UInt16,
        label: String?,
        sendHandler: @escaping @Sendable (LoomSessionStreamEnvelope) async throws -> Void
    ) {
        self.id = id
        self.label = label
        self.sendHandler = sendHandler
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        incomingBytes = stream
        self.continuation = continuation
    }

    public func send(_ data: Data) async throws {
        try await sendHandler(
            LoomSessionStreamEnvelope(
                kind: .data,
                streamID: id,
                label: nil,
                payload: data
            )
        )
    }

    public func close() async throws {
        try await sendHandler(
            LoomSessionStreamEnvelope(
                kind: .close,
                streamID: id,
                label: nil,
                payload: nil
            )
        )
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

/// Authenticated Loom session that provides generic multiplexed streams.
public actor LoomAuthenticatedSession {
    public let rawSession: LoomSession
    public let role: LoomSessionRole
    public let transportKind: LoomTransportKind

    public nonisolated let incomingStreams: AsyncStream<LoomMultiplexedStream>

    public private(set) var state: LoomAuthenticatedSessionState = .idle
    public private(set) var context: LoomAuthenticatedSessionContext?

    private let framedConnection: LoomFramedConnection
    private let incomingStreamContinuation: AsyncStream<LoomMultiplexedStream>.Continuation
    private var streams: [UInt16: LoomMultiplexedStream] = [:]
    private var nextOutgoingStreamID: UInt16
    private var readTask: Task<Void, Never>?
    private var securityContext: LoomSessionSecurityContext?

    public init(
        rawSession: LoomSession,
        role: LoomSessionRole,
        transportKind: LoomTransportKind
    ) {
        self.rawSession = rawSession
        self.role = role
        self.transportKind = transportKind
        framedConnection = LoomFramedConnection(connection: rawSession.connection)
        let (stream, continuation) = AsyncStream.makeStream(of: LoomMultiplexedStream.self)
        incomingStreams = stream
        incomingStreamContinuation = continuation
        nextOutgoingStreamID = role == .initiator ? 1 : 2
    }

    deinit {
        incomingStreamContinuation.finish()
        readTask?.cancel()
    }

    public func start(
        localHello: LoomSessionHelloRequest,
        identityManager: LoomIdentityManager,
        trustProvider: (any LoomTrustProvider)? = nil,
        helloValidator: LoomSessionHelloValidator = LoomSessionHelloValidator(),
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) async throws -> LoomAuthenticatedSessionContext {
        guard case .idle = state else {
            if let context {
                return context
            }
            throw LoomError.protocolError("Authenticated Loom session has already started.")
        }

        state = .handshaking
        rawSession.start(queue: queue)
        try await framedConnection.awaitReady()

        let preparedHello = try await MainActor.run {
            try LoomSessionHelloValidator.makePreparedSignedHello(
                from: localHello,
                identityManager: identityManager
            )
        }
        let helloData = try JSONEncoder().encode(preparedHello.hello)
        try await framedConnection.sendFrame(helloData)

        let remoteHelloData = try await framedConnection.readFrame(
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
        guard negotiatedFeatures.contains("loom.session-encryption.v1") else {
            state = .failed("missing-session-encryption")
            rawSession.cancel()
            throw LoomError.protocolError("Peer does not support Loom authenticated session encryption.")
        }

        let trustEvaluation = await resolveTrustEvaluation(
            for: peerIdentity,
            trustProvider: trustProvider
        )
        if trustEvaluation.decision == .denied {
            state = .failed("denied")
            rawSession.cancel()
            throw LoomError.authenticationFailed
        }

        securityContext = try LoomSessionSecurityContext(
            role: role,
            localHello: preparedHello.hello,
            remoteHello: validatedHello.hello,
            localEphemeralPrivateKey: preparedHello.ephemeralPrivateKey
        )
        let context = LoomAuthenticatedSessionContext(
            peerIdentity: peerIdentity,
            trustEvaluation: trustEvaluation,
            transportKind: transportKind,
            negotiatedFeatures: negotiatedFeatures
        )
        self.context = context
        state = .ready
        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
        return context
    }

    public func openStream(label: String? = nil) async throws -> LoomMultiplexedStream {
        guard case .ready = state else {
            throw LoomError.protocolError("Authenticated Loom session is not ready.")
        }
        let streamID = nextOutgoingStreamID
        nextOutgoingStreamID &+= 2
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

    public func cancel() {
        state = .cancelled
        readTask?.cancel()
        for stream in streams.values {
            stream.finishInbound()
        }
        streams.removeAll(keepingCapacity: false)
        incomingStreamContinuation.finish()
        rawSession.cancel()
    }

    private func runReadLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await framedConnection.readFrame(
                    maxBytes: LoomMessageLimits.maxFrameBytes
                )
                let envelope = try decryptEnvelope(data)
                try await handleEnvelope(envelope)
            }
        } catch {
            if case .cancelled = state {
                return
            }
            state = .failed(error.localizedDescription)
            for stream in streams.values {
                stream.finishInbound()
            }
            streams.removeAll(keepingCapacity: false)
            incomingStreamContinuation.finish()
            rawSession.cancel()
        }
    }

    private func handleEnvelope(_ envelope: LoomSessionStreamEnvelope) async throws {
        switch envelope.kind {
        case .open:
            let stream = makeStream(id: envelope.streamID, label: envelope.label)
            streams[envelope.streamID] = stream
            incomingStreamContinuation.yield(stream)
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
        LoomMultiplexedStream(id: id, label: label) { [weak self] envelope in
            guard let self else {
                throw LoomError.protocolError("Authenticated Loom session no longer exists.")
            }
            try await self.sendEnvelope(envelope)
            if envelope.kind == .close {
                await self.removeStream(id: envelope.streamID)
            }
        }
    }

    private func removeStream(id: UInt16) {
        streams.removeValue(forKey: id)
    }

    private func sendEnvelope(_ envelope: LoomSessionStreamEnvelope) async throws {
        let trafficClass = envelope.kind == .data ? LoomSessionTrafficClass.data : .control
        let encodedEnvelope = try envelope.encode()
        guard var securityContext else {
            throw LoomError.protocolError("Authenticated Loom session encryption context is unavailable.")
        }
        let encryptedPayload = try securityContext.seal(
            encodedEnvelope,
            trafficClass: trafficClass
        )
        self.securityContext = securityContext

        var wireFrame = Data(capacity: encryptedPayload.count + 1)
        wireFrame.append(trafficClass.rawValue)
        wireFrame.append(encryptedPayload)
        try await framedConnection.sendFrame(wireFrame)
    }

    private func decryptEnvelope(_ wireFrame: Data) throws -> LoomSessionStreamEnvelope {
        guard let trafficClassRaw = wireFrame.first,
              let trafficClass = LoomSessionTrafficClass(rawValue: trafficClassRaw) else {
            throw LoomError.protocolError("Received Loom session frame with invalid traffic class.")
        }
        guard var securityContext else {
            throw LoomError.protocolError("Authenticated Loom session encryption context is unavailable.")
        }
        let encryptedPayload = Data(wireFrame.dropFirst())
        let plaintext = try securityContext.open(
            encryptedPayload,
            trafficClass: trafficClass
        )
        self.securityContext = securityContext
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
        let labelLength = UInt16(clamping: labelBytes.count)
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
