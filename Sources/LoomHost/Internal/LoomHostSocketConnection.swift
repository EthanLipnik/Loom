//
//  LoomHostSocketConnection.swift
//  LoomHost
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

#if os(macOS)
import Darwin

package actor LoomHostSocketConnection {
    private static let maximumBufferedFrameBytes = 1_048_576
    private static let maximumPendingFrameCount = 32

    private let encoder = JSONEncoder()
    private let onFrame: @Sendable (LoomHostIPCFrame) async -> Void
    private let onClosed: @Sendable () async -> Void

    private nonisolated let descriptor: LoomHostSocketDescriptor
    private var readTask: Task<Void, Never>?
    private var frameDispatcher: LoomHostSocketFrameDispatcher?
    private var isClosed = false
    private var hasNotifiedClosed = false

    package static func connect(
        to path: String,
        onFrame: @escaping @Sendable (LoomHostIPCFrame) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) async throws -> LoomHostSocketConnection {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = try makeAddress(for: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socketFD,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connectResult == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
            Darwin.close(socketFD)
            throw error
        }

        let connection = LoomHostSocketConnection(
            fileDescriptor: socketFD,
            onFrame: onFrame,
            onClosed: onClosed
        )
        await connection.startReading()
        return connection
    }

    package init(
        fileDescriptor: Int32,
        onFrame: @escaping @Sendable (LoomHostIPCFrame) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) {
        descriptor = LoomHostSocketDescriptor(fileDescriptor: fileDescriptor)
        self.onFrame = onFrame
        self.onClosed = onClosed
        Self.configureSocket(fileDescriptor: fileDescriptor)
    }

    deinit {
        readTask?.cancel()
        frameDispatcher?.close()
        descriptor.hardClose()
    }

    package func send(_ frame: LoomHostIPCFrame) throws {
        let encoded = try encoder.encode(frame)
        var line = encoded
        line.append(0x0A)
        try descriptor.writeAll(line)
    }

    package func startReading() {
        guard readTask == nil else {
            return
        }
        let descriptor = self.descriptor
        let frameDispatcher = LoomHostSocketFrameDispatcher(
            maximumRetainedFrameCount: Self.maximumPendingFrameCount,
            onFrame: onFrame
        )
        self.frameDispatcher = frameDispatcher
        readTask = Task.detached { [weak self] in
            await Self.runReadLoop(
                descriptor: descriptor,
                frameDispatcher: frameDispatcher
            )
            await self?.handleReadLoopFinished(frameDispatcher: frameDispatcher)
        }
    }

    package func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        let task = readTask
        let frameDispatcher = frameDispatcher
        readTask = nil
        self.frameDispatcher = nil
        task?.cancel()
        frameDispatcher?.close()
        descriptor.hardClose()
        _ = await task?.result
        await notifyClosedIfNeeded()
        await frameDispatcher?.waitForQuiescence()
    }

    /// Interrupts a blocked actor-isolated write before `close()` can enter the socket actor.
    /// Descriptor leases keep the numeric file descriptor from being reused until every active
    /// syscall observes shutdown and exits.
    package nonisolated func hardCloseNow() {
        descriptor.hardClose()
    }

    /// Test visibility proves the hard-cut path interrupts an in-flight syscall rather than merely
    /// winning a race before the write begins.
    package nonisolated var hasActiveSocketOperationForTesting: Bool {
        descriptor.hasActiveOperation
    }

    private static func runReadLoop(
        descriptor: LoomHostSocketDescriptor,
        frameDispatcher: LoomHostSocketFrameDispatcher
    ) async {
        let decoder = JSONDecoder()
        var bufferedData = Data()
        var readBuffer = [UInt8](repeating: 0, count: 4096)
        defer { frameDispatcher.close() }

        while !Task.isCancelled {
            let readCount = readBuffer.withUnsafeMutableBytes { rawBuffer in
                descriptor.read(into: rawBuffer)
            }

            if readCount > 0 {
                bufferedData.append(readBuffer, count: readCount)
                if bufferedData.count > Self.maximumBufferedFrameBytes {
                    break
                }
                while let newlineIndex = bufferedData.firstIndex(of: 0x0A) {
                    if newlineIndex > Self.maximumBufferedFrameBytes {
                        bufferedData.removeAll(keepingCapacity: false)
                        break
                    }
                    let frameData = bufferedData.prefix(upTo: newlineIndex)
                    bufferedData.removeSubrange(...newlineIndex)
                    guard !frameData.isEmpty else {
                        continue
                    }
                    do {
                        let frame = try decoder.decode(
                            LoomHostIPCFrame.self,
                            from: Data(frameData)
                        )
                        guard frameDispatcher.enqueue(frame) else {
                            // A blocked handler cannot permit unbounded retained IPC payloads.
                            return
                        }
                    } catch {
                        break
                    }
                }
                continue
            }

            if readCount == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            break
        }
    }

    private func handleReadLoopFinished(
        frameDispatcher: LoomHostSocketFrameDispatcher
    ) async {
        readTask = nil
        descriptor.hardClose()
        frameDispatcher.close()
        // EOF first reaches the broker's out-of-band cleanup, which interrupts an active handler
        // suspended in transport. Quiescence then proves no handler outlives socket teardown.
        await notifyClosedIfNeeded()
        await frameDispatcher.waitForQuiescence()
        if self.frameDispatcher === frameDispatcher {
            self.frameDispatcher = nil
        }
    }

    private func notifyClosedIfNeeded() async {
        guard !hasNotifiedClosed else {
            return
        }
        hasNotifiedClosed = true
        await onClosed()
    }

    private static func configureSocket(fileDescriptor: Int32) {
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { pointer in
            Darwin.setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }
}

/// Owns one Unix descriptor independently from the socket actor. Shutdown marks the descriptor
/// unavailable first, interrupts active syscalls, and delays numeric descriptor reuse until those
/// syscalls leave their leases.
private final class LoomHostSocketDescriptor: @unchecked Sendable {
    private let condition = NSCondition()
    private var fileDescriptor: Int32
    private var generation: UInt64 = 1
    private var activeOperationCount = 0

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        hardClose()
    }

    var hasActiveOperation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return activeOperationCount > 0
    }

    func writeAll(_ data: Data) throws {
        guard let operation = beginOperation() else {
            throw POSIXError(.ECANCELED)
        }
        defer { finishOperation() }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesSent = 0
            while bytesSent < rawBuffer.count {
                guard isCurrent(operation) else { throw POSIXError(.ECANCELED) }
                let written = Darwin.write(
                    operation.fileDescriptor,
                    baseAddress.advanced(by: bytesSent),
                    rawBuffer.count - bytesSent
                )
                if written < 0 {
                    let writeError = errno
                    if writeError == EINTR, isCurrent(operation) { continue }
                    throw POSIXError(.init(rawValue: writeError) ?? .EIO)
                }
                guard written > 0 else { throw POSIXError(.EPIPE) }
                bytesSent += written
            }
            guard isCurrent(operation) else { throw POSIXError(.ECANCELED) }
        }
    }

    func read(into rawBuffer: UnsafeMutableRawBufferPointer) -> Int {
        guard let operation = beginOperation() else { return 0 }
        defer { finishOperation() }
        let count = Darwin.read(
            operation.fileDescriptor,
            rawBuffer.baseAddress,
            rawBuffer.count
        )
        let readError = errno
        guard isCurrent(operation) else { return 0 }
        errno = readError
        return count
    }

    func hardClose() {
        condition.lock()
        guard fileDescriptor >= 0 else {
            condition.unlock()
            return
        }
        let closingDescriptor = fileDescriptor
        fileDescriptor = -1
        generation = generation == UInt64.max ? 1 : generation + 1
        condition.unlock()

        // `shutdown` interrupts both read and a backpressured write without waiting for the actor
        // that owns those calls. The descriptor remains allocated until their leases exit.
        Darwin.shutdown(closingDescriptor, SHUT_RDWR)
        condition.lock()
        while activeOperationCount > 0 {
            condition.wait()
        }
        condition.unlock()
        Darwin.close(closingDescriptor)
    }

    private func beginOperation() -> (fileDescriptor: Int32, generation: UInt64)? {
        condition.lock()
        defer { condition.unlock() }
        guard fileDescriptor >= 0 else { return nil }
        activeOperationCount += 1
        return (fileDescriptor, generation)
    }

    private func finishOperation() {
        condition.lock()
        activeOperationCount -= 1
        if activeOperationCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func isCurrent(_ operation: (fileDescriptor: Int32, generation: UInt64)) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return fileDescriptor == operation.fileDescriptor
            && generation == operation.generation
    }
}

/// Runs one ordered handler at a time. EOF clears queued payloads immediately, cancels the sole
/// worker, and exposes quiescence separately so broker hard-cut cleanup can unblock active work.
private final class LoomHostSocketFrameDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumRetainedFrameCount: Int
    private let onFrame: @Sendable (LoomHostIPCFrame) async -> Void
    private var queuedFrames: [LoomHostIPCFrame] = []
    private var workerTask: Task<Void, Never>?
    private var isOpen = true

    init(
        maximumRetainedFrameCount: Int,
        onFrame: @escaping @Sendable (LoomHostIPCFrame) async -> Void
    ) {
        self.maximumRetainedFrameCount = maximumRetainedFrameCount
        self.onFrame = onFrame
    }

    func enqueue(_ frame: LoomHostIPCFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let retainedFrameCount = queuedFrames.count + (workerTask == nil ? 0 : 1)
        guard isOpen, retainedFrameCount < maximumRetainedFrameCount else {
            return false
        }
        queuedFrames.append(frame)
        if workerTask == nil {
            workerTask = Task { [weak self] in
                await self?.runWorker()
            }
        }
        return true
    }

    func close() {
        lock.lock()
        guard isOpen else {
            lock.unlock()
            return
        }
        isOpen = false
        // The active handler owns only its current frame. Clearing this array releases every
        // queued IPC payload without waiting for that handler to observe cancellation.
        queuedFrames.removeAll(keepingCapacity: false)
        let workerTask = workerTask
        lock.unlock()
        workerTask?.cancel()
    }

    func waitForQuiescence() async {
        let workerTask = currentWorkerTask()
        _ = await workerTask?.result
    }

    private func currentWorkerTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let workerTask = workerTask
        return workerTask
    }

    private func runWorker() async {
        defer { finishWorker() }
        while !Task.isCancelled {
            guard let frame = takeNextFrame() else {
                return
            }
            await onFrame(frame)
        }
    }

    private func takeNextFrame() -> LoomHostIPCFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen, !queuedFrames.isEmpty else {
            return nil
        }
        return queuedFrames.removeFirst()
    }

    private func finishWorker() {
        lock.lock()
        workerTask = nil
        if isOpen, !queuedFrames.isEmpty {
            // Enqueue and worker retirement share this lock, so no frame can be stranded between
            // observing an empty queue and installing its successor worker.
            workerTask = Task { [weak self] in
                await self?.runWorker()
            }
        }
        lock.unlock()
    }
}

package func makeAddress(for path: String) throws -> sockaddr_un {
    let utf8Path = Array(path.utf8)
    guard utf8Path.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw LoomHostError.socketPathTooLong
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return
        }
        baseAddress.initialize(repeating: 0, count: rawBuffer.count)
        _ = utf8Path.withUnsafeBufferPointer { buffer in
            memcpy(baseAddress, buffer.baseAddress, buffer.count)
        }
    }
    return address
}
#else
package actor LoomHostSocketConnection {
    package static func connect(
        to _: String,
        onFrame _: @escaping @Sendable (LoomHostIPCFrame) async -> Void,
        onClosed _: @escaping @Sendable () async -> Void
    ) async throws -> LoomHostSocketConnection {
        throw LoomHostError.unsupportedPlatform
    }

    package init(
        fileDescriptor _: Int32,
        onFrame _: @escaping @Sendable (LoomHostIPCFrame) async -> Void,
        onClosed _: @escaping @Sendable () async -> Void
    ) {}

    package func send(_: LoomHostIPCFrame) throws {
        throw LoomHostError.unsupportedPlatform
    }

    package func startReading() {}

    package func close() async {}
}
#endif
