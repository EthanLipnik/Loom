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

    func sendCapture(
        at fileURL: URL,
        over connection: LoomConnectionHandle
    ) async throws {
        _ = try await connection.sendFile(
            at: fileURL,
            named: "capture.png",
            contentType: "image/png"
        )
    }

    func sendRenderedFrame(
        _ data: Data,
        over connection: LoomConnectionHandle
    ) async throws {
        _ = try await connection.sendData(
            data,
            named: "frame.bin",
            contentType: "application/octet-stream"
        )
    }
}
