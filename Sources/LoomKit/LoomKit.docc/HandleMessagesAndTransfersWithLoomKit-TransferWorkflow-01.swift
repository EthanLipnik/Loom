import Foundation
import LoomKit

struct TransferWorkflow {
    func acceptIncomingTransfers(
        from connection: LoomConnectionHandle,
        into downloadsDirectory: URL
    ) {
        Task {
            for await transfer in connection.incomingTransfers {
                let destinationURL = downloadsDirectory.appendingPathComponent(
                    transfer.offer.logicalName
                )
                try? await connection.accept(
                    transfer,
                    to: destinationURL,
                    resumeIfPossible: true
                )
            }
        }
    }
}
