//
//  LoomHostSocketConnection.swift
//  LoomHost
//
//  Created by Codex on 3/10/26.
//

import Foundation

#if os(macOS)
import Darwin

package actor LoomHostSocketConnection {
    private static let maximumBufferedFrameBytes = 1_048_576

    private let encoder = JSONEncoder()
    private let onFrame: @Sendable (LoomHostIPCFrame) async -> Void
    private let onClosed: @Sendable () async -> Void

    private var fileDescriptor: Int32
    private var readTask: Task<Void, Never>?
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
        self.fileDescriptor = fileDescriptor
        self.onFrame = onFrame
        self.onClosed = onClosed
        Self.configureSocket(fileDescriptor: fileDescriptor)
    }

    deinit {
        readTask?.cancel()
        if fileDescriptor >= 0 {
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
        }
    }

    package func send(_ frame: LoomHostIPCFrame) throws {
        let encoded = try encoder.encode(frame)
        var line = encoded
        line.append(0x0A)
        try line.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var bytesSent = 0
            while bytesSent < rawBuffer.count {
                let written = Darwin.write(
                    fileDescriptor,
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
    }

    package func startReading() {
        guard readTask == nil else {
            return
        }
        let fileDescriptor = self.fileDescriptor
        let onFrame = self.onFrame
        readTask = Task.detached { [weak self] in
            await Self.runReadLoop(
                fileDescriptor: fileDescriptor,
                onFrame: onFrame
            )
            await self?.handleReadLoopFinished()
        }
    }

    package func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        let task = readTask
        readTask = nil
        task?.cancel()
        closeFileDescriptor()
        _ = await task?.result
        await notifyClosedIfNeeded()
    }

    private static func runReadLoop(
        fileDescriptor: Int32,
        onFrame: @escaping @Sendable (LoomHostIPCFrame) async -> Void
    ) async {
        let decoder = JSONDecoder()
        var bufferedData = Data()
        var readBuffer = [UInt8](repeating: 0, count: 4096)

        while !Task.isCancelled {
            let readCount = readBuffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    fileDescriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
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
                        await onFrame(frame)
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

    private func handleReadLoopFinished() async {
        readTask = nil
        closeFileDescriptor()
        await notifyClosedIfNeeded()
    }

    private func closeFileDescriptor() {
        guard fileDescriptor >= 0 else {
            return
        }
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
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
