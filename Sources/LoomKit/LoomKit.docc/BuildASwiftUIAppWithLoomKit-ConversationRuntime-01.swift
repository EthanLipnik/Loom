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
}
