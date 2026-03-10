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

    func acceptShare(
        metadata: CKShare.Metadata,
        using loomContext: LoomContext
    ) async throws {
        try await loomContext.acceptShare(metadata)
        await loomContext.refreshPeers()
    }
}
