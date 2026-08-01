@testable import LoomSharedRuntime
import Darwin
import Foundation
import Testing

@Suite("LoomHostSocketConnection")
struct LoomHostSocketConnectionTests {
    @Test("A hard close interrupts a backpressured Unix socket write")
    func hardCloseInterruptsBlockedWrite() async throws {
        var sockets = [Int32](repeating: 0, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { Darwin.close(sockets[1]) }

        var sendBufferBytes: Int32 = 4_096
        _ = withUnsafePointer(to: &sendBufferBytes) { pointer in
            Darwin.setsockopt(
                sockets[0],
                SOL_SOCKET,
                SO_SNDBUF,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        let writer = LoomHostSocketConnection(
            fileDescriptor: sockets[0],
            onFrame: { _ in },
            onClosed: {}
        )
        let sendTask = Task<Result<Void, any Error>, Never> {
            do {
                try await writer.send(
                    LoomHostIPCFrame(
                        requestID: UUID(),
                        message: .streamData(
                            clientID: UUID(),
                            connectionID: UUID(),
                            streamID: 1,
                            payloadBase64: String(repeating: "A", count: 4 * 1_024 * 1_024)
                        )
                    )
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        #expect(await waitForSocketCondition(timeout: .seconds(2)) {
            writer.hasActiveSocketOperationForTesting
        })
        writer.hardCloseNow()
        let result = await valueBeforeDeadline(from: sendTask, timeout: .seconds(2))
        #expect(result != nil)
        if case .some(.success) = result {
            Issue.record("A backpressured write unexpectedly completed after its hard cut.")
        }
        await writer.close()
    }

    @Test("Socket closure bypasses a suspended ordered frame handler")
    func socketClosureQuiescesOutOfBand() async {
        var sockets = [Int32](repeating: 0, count: 2)
        let socketResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
        #expect(socketResult == 0)
        guard socketResult == 0 else { return }

        let probe = LoomHostSocketHardCutProbe()
        let reader = LoomHostSocketConnection(
            fileDescriptor: sockets[0],
            onFrame: { _ in
                await probe.handleFrame()
            },
            onClosed: {
                await probe.markSocketClosed()
            }
        )
        let writer = LoomHostSocketConnection(
            fileDescriptor: sockets[1],
            onFrame: { _ in },
            onClosed: {}
        )
        await reader.startReading()

        do {
            for _ in 0..<2 {
                try await writer.send(
                    LoomHostIPCFrame(
                        requestID: UUID(),
                        message: .reply(status: .ok)
                    )
                )
            }
        } catch {
            Issue.record("Failed to submit the broker IPC test frame: \(error)")
            await writer.close()
            await reader.close()
            return
        }

        #expect(await waitForSocketCondition { await probe.hasFrameStarted })
        await writer.close()
        #expect(await waitForSocketCondition { await probe.hasSocketClosed })
        #expect(!(await probe.hasFrameExited))

        let readerCloseTask = Task {
            await reader.close()
            await probe.markReaderCloseFinished()
        }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!(await probe.hasReaderCloseFinished))

        await probe.releaseFrame()
        #expect(await waitForSocketCondition { await probe.hasFrameExited })
        #expect(await waitForSocketCondition { await probe.hasReaderCloseFinished })
        #expect(await probe.handledFrameCount == 1)
        _ = await readerCloseTask.result
    }

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

private actor LoomHostSocketHardCutProbe {
    private var frameContinuation: CheckedContinuation<Void, Never>?
    private(set) var hasFrameStarted = false
    private(set) var hasFrameExited = false
    private(set) var hasSocketClosed = false
    private(set) var hasReaderCloseFinished = false
    private(set) var handledFrameCount = 0

    func handleFrame() async {
        handledFrameCount += 1
        hasFrameStarted = true
        await withCheckedContinuation { continuation in
            frameContinuation = continuation
        }
        hasFrameExited = true
    }

    func releaseFrame() {
        frameContinuation?.resume()
        frameContinuation = nil
    }

    func markSocketClosed() {
        hasSocketClosed = true
    }

    func markReaderCloseFinished() {
        hasReaderCloseFinished = true
    }
}

private func waitForSocketCondition(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
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

private func valueBeforeDeadline<Value: Sendable>(
    from task: Task<Value, Never>,
    timeout: Duration
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await task.value }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let value = await group.next() ?? nil
        group.cancelAll()
        return value
    }
}
