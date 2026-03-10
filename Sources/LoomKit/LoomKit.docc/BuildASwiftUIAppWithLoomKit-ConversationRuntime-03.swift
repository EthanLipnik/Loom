import Foundation
import LoomKit
import Observation

@Observable
@MainActor
final class ConversationRuntime {
    private(set) var transcript: [String] = []

    func start(using loomContext: LoomContext) {
        Task {
            for await connection in loomContext.incomingConnections {
                Task {
                    for await payload in connection.messages {
                        let line = String(decoding: payload, as: UTF8.self)
                        await MainActor.run {
                            self.transcript.append(line)
                        }
                    }
                }
            }
        }
    }

    func connectAndSendGreeting(
        to peer: LoomPeerSnapshot,
        using loomContext: LoomContext
    ) async throws -> LoomConnectionHandle {
        let connection = try await loomContext.connect(peer)
        try await connection.send("hello")
        return connection
    }

    func sendScreenshot(
        at url: URL,
        over connection: LoomConnectionHandle
    ) async throws {
        _ = try await connection.sendFile(
            at: url,
            named: "capture.png",
            contentType: "image/png"
        )
    }
}
