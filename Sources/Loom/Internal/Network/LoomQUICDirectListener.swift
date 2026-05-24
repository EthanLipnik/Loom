//
//  LoomQUICDirectListener.swift
//  Loom
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Foundation
import Network

package actor LoomQUICDirectListener: LoomDirectTransportListener {
    private let enablePeerToPeer: Bool
    private let quicALPN: [String]
    private let serviceClass: NWParameters.ServiceClass
    private var listener: NetworkListener<QUIC>?
    private var runTask: Task<Void, Never>?

    package init(
        enablePeerToPeer: Bool,
        quicALPN: [String],
        serviceClass: NWParameters.ServiceClass
    ) {
        self.enablePeerToPeer = enablePeerToPeer
        self.quicALPN = quicALPN
        self.serviceClass = serviceClass
    }

    package func start(
        port requestedPort: UInt16,
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16 {
        let listener = try LoomQUICTransportFactory.makeListener(
            port: requestedPort,
            enablePeerToPeer: enablePeerToPeer,
            quicALPN: quicALPN,
            serviceClass: serviceClass
        )
        self.listener = listener

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = LoomQUICListenerReadyContinuationBox(continuation: continuation)
            listener.onStateUpdate { _, state in
                switch state {
                case .ready:
                    box.complete(.success(()))
                case let .failed(error):
                    box.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                case .cancelled:
                    box.complete(
                        .failure(
                            LoomError.connectionFailed(
                                LoomConnectionFailure(reason: .cancelled, detail: "QUIC listener cancelled.")
                            )
                        )
                    )
                case let .waiting(error):
                    LoomLogger.transport("QUIC listener waiting: \(error)")
                case .setup:
                    break
                @unknown default:
                    break
                }
            }

            runTask = Task { [listener] in
                do {
                    try await listener.run { connection in
                        onConnection(.quic(connection))
                    }
                } catch {
                    box.complete(.failure(LoomError.connectionFailed(LoomConnectionFailure.classify(error))))
                    LoomLogger.transport("QUIC listener stopped: \(error)")
                }
            }
        }

        guard let port = listener.port?.rawValue else {
            throw LoomError.protocolError("QUIC listener started without a bound port.")
        }
        LoomLogger.transport("QUIC listener started on port \(port)")
        return port
    }

    package func stop() async {
        runTask?.cancel()
        runTask = nil
        listener = nil
    }
}

private final class LoomQUICListenerReadyContinuationBox: @unchecked Sendable {
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
