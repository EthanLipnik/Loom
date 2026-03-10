import CloudKit
import LoomKit
import Observation

@Observable
@MainActor
final class SharingCoordinator {
    private(set) var activeShare: CKShare?

    func createShare(using loomContext: LoomContext) async throws {
        activeShare = try await loomContext.createShare()
    }
}
