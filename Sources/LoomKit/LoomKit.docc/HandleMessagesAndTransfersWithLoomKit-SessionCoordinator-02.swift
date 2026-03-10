import Foundation
import LoomKit
import Observation

@Observable
@MainActor
final class SessionCoordinator {
    private(set) var transcript: [String] = []
    private(set) var statusLine = "Idle"

    func attach(to connection: LoomConnectionHandle) {
        Task {
            for await payload in connection.messages {
                let line = String(decoding: payload, as: UTF8.self)
                await MainActor.run {
                    self.transcript.append(line)
                }
            }
        }

        Task {
            for await event in connection.events {
                await MainActor.run {
                    switch event {
                    case let .stateChanged(state):
                        self.statusLine = state.rawValue
                    case let .disconnected(message):
                        self.statusLine = message ?? "disconnected"
                    case .incomingTransfer, .message:
                        break
                    }
                }
            }
        }
    }
}
