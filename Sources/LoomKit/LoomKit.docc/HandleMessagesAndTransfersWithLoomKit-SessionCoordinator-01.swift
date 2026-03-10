import Foundation
import LoomKit
import Observation

@Observable
@MainActor
final class SessionCoordinator {
    private(set) var transcript: [String] = []

    func attach(to connection: LoomConnectionHandle) {
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
