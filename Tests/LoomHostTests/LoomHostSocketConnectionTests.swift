@testable import LoomSharedRuntime
import Darwin
import Foundation
import Testing

@Suite("LoomHostSocketConnection")
struct LoomHostSocketConnectionTests {
    @Test("Read loop closes connection when buffered frame exceeds maximum size")
    func closesConnectionWhenBufferedFrameIsTooLarge() async throws {
        var sockets = [Int32](repeating: 0, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            Darwin.close(sockets[1])
        }

        let connectionClosed = AsyncStream<Void> { continuation in
            let connection = LoomHostSocketConnection(
                fileDescriptor: sockets[0],
                onFrame: { _ in },
                onClosed: {
                    continuation.yield(())
                    continuation.finish()
                }
            )
            continuation.onTermination = { _ in
                Task {
                    await connection.close()
                }
            }
            Task {
                await connection.startReading()
            }
        }

        var oversizedFrame = Data(
            repeating: 0x61,
            count: 1_048_577
        )
        try oversizedFrame.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesSent = 0
            while bytesSent < rawBuffer.count {
                let written = Darwin.write(
                    sockets[1],
                    baseAddress.advanced(by: bytesSent),
                    rawBuffer.count - bytesSent
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesSent += written
            }
        }
        oversizedFrame.removeAll(keepingCapacity: false)

        let didClose = await nextValue(from: connectionClosed, timeout: .seconds(2))
        #expect(didClose != nil)
    }
}

private func nextValue<Element: Sendable>(
    from stream: AsyncStream<Element>,
    timeout: Duration
) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            return nil
        }

        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }

        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
