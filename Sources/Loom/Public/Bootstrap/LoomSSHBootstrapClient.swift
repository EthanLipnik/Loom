//
//  LoomSSHBootstrapClient.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  SSH abstraction for authenticated bootstrap over SSH.
//

import Foundation
#if canImport(NIOConcurrencyHelpers) && canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
#endif

/// Result of an SSH bootstrap unlock attempt.
public struct LoomSSHBootstrapResult: Sendable, Equatable {
    /// Whether the remote endpoint completed the requested unlock flow.
    public let unlocked: Bool

    /// Creates an SSH bootstrap result.
    ///
    /// - Parameter unlocked: `true` when the target completed the unlock flow.
    public init(unlocked: Bool) {
        self.unlocked = unlocked
    }
}

/// SSH bootstrap errors.
public enum LoomSSHBootstrapError: LocalizedError, Sendable, Equatable {
    case unsupported
    case connectionFailed(String)
    case authenticationFailed
    case timedOut
    case invalidEndpoint
    case invalidServerTrustConfiguration(String)

    /// Human-readable error text for UI and diagnostics.
    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "SSH bootstrap is not available on this platform build."
        case let .connectionFailed(detail):
            "SSH bootstrap connection failed: \(detail)"
        case .authenticationFailed:
            "SSH bootstrap credential validation failed."
        case .timedOut:
            "SSH bootstrap timed out."
        case .invalidEndpoint:
            "SSH bootstrap endpoint is invalid."
        case let .invalidServerTrustConfiguration(detail):
            "SSH bootstrap requires a valid SSH host trust configuration: \(detail)"
        }
    }
}

/// Cross-platform SSH client contract for bootstrap unlock flows.
public protocol LoomSSHBootstrapClient: Sendable {
    /// Attempts a remote unlock flow over SSH.
    ///
    /// - Parameters:
    ///   - endpoint: Host endpoint to contact.
    ///   - username: Account username used for SSH authentication.
    ///   - password: Account password used for SSH authentication.
    ///   - serverTrust: SSH host-certificate trust configuration.
    ///   - timeout: End-to-end timeout for connection and auth probe.
    /// - Returns: Unlock status returned by the SSH bootstrap implementation.
    /// - Throws: ``LoomSSHBootstrapError`` on auth, transport, or timeout failures.
    func unlockVolumeOverSSH(
        endpoint: LoomBootstrapEndpoint,
        username: String,
        password: String,
        serverTrust: LoomSSHServerTrustConfiguration,
        timeout: Duration
    ) async throws -> LoomSSHBootstrapResult
}

/// Default implementation placeholder.
///
/// Platforms can inject a concrete implementation where available.
public struct LoomDefaultSSHBootstrapClient: LoomSSHBootstrapClient {
    /// Creates the default SSH bootstrap client.
    ///
    /// This implementation uses SwiftNIO/NIOSSH when those dependencies are available at build time.
    public init() {}

    /// Executes the default SSH bootstrap probe.
    ///
    /// The default implementation authenticates with password credentials. A successful
    /// authentication followed by an immediate disconnect is treated as expected progress
    /// for macOS FileVault pre-login SSH unlock.
    public func unlockVolumeOverSSH(
        endpoint: LoomBootstrapEndpoint,
        username: String,
        password: String,
        serverTrust: LoomSSHServerTrustConfiguration,
        timeout: Duration
    )
    async throws -> LoomSSHBootstrapResult {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw LoomSSHBootstrapError.invalidEndpoint }
        guard endpoint.port > 0 else { throw LoomSSHBootstrapError.invalidEndpoint }
        let trustValidator: LoomSSHServerTrustValidator
        do {
            trustValidator = try LoomSSHServerTrustValidator(configuration: serverTrust)
        } catch let error as LoomSSHServerTrustError {
            throw LoomSSHBootstrapError.invalidServerTrustConfiguration(
                error.localizedDescription
            )
        }

#if canImport(NIOConcurrencyHelpers) && canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
        let timeoutNanoseconds = Self.timeoutNanoseconds(timeout)
        guard timeoutNanoseconds > 0 else { throw LoomSSHBootstrapError.timedOut }
        let timeoutDuration = Duration.nanoseconds(Int64(clamping: timeoutNanoseconds))

        return try await withThrowingTaskGroup(of: LoomSSHBootstrapResult.self) { group in
            group.addTask {
                try await Self.performCredentialSubmission(
                    host: host,
                    port: Int(endpoint.port),
                    username: username,
                    password: password,
                    trustValidator: trustValidator
                )
            }
            group.addTask {
                try await Task.sleep(for: timeoutDuration)
                throw LoomSSHBootstrapError.timedOut
            }

            guard let first = try await group.next() else {
                throw LoomSSHBootstrapError.connectionFailed("Missing SSH bootstrap result.")
            }
            group.cancelAll()
            return first
        }
#else
        throw LoomSSHBootstrapError.unsupported
#endif
    }
}

#if canImport(NIOConcurrencyHelpers) && canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
private extension LoomDefaultSSHBootstrapClient {
    static func performCredentialSubmission(
        host: String,
        port: Int,
        username: String,
        password: String,
        trustValidator: LoomSSHServerTrustValidator
    ) async throws -> LoomSSHBootstrapResult {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let authDelegate = SinglePasswordAuthenticationDelegate(
            username: username,
            password: password
        )
        let serverAuthDelegate = HostKeyValidationDelegate(trustValidator: trustValidator)

        do {
            let bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sshHandler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: authDelegate,
                                    serverAuthDelegate: serverAuthDelegate
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(sshHandler)
                    }
                }
                .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
                .channelOption(ChannelOptions.socket(
                    SocketOptionLevel(SOL_SOCKET),
                    SO_REUSEADDR
                ), value: 1)
                .channelOption(ChannelOptions.socket(
                    SocketOptionLevel(IPPROTO_TCP),
                    TCP_NODELAY
                ), value: 1)

            let channel = try await bootstrap.connect(host: host, port: port).get()
            defer {
                _ = channel.close(mode: .all)
            }

            let childChannel = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let childPromise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(childPromise, channelType: .session) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(
                            LoomSSHBootstrapError.connectionFailed("Unexpected SSH channel type.")
                        )
                    }
                    return childChannel.eventLoop.makeSucceededFuture(())
                }
                return childPromise.futureResult
            }.get()

            try? await childChannel.close(mode: .all).get()
            try await shutdownEventLoopGroup(eventLoopGroup)
            return LoomSSHBootstrapResult(unlocked: true)
        } catch let error as LoomSSHBootstrapError {
            try? await shutdownEventLoopGroup(eventLoopGroup)
            if authDelegate.didOfferPassword,
               Self.isExpectedFileVaultDisconnect(error) {
                return LoomSSHBootstrapResult(unlocked: true)
            }
            throw error
        } catch {
            try? await shutdownEventLoopGroup(eventLoopGroup)
            let mappedError = mapToBootstrapError(error)
            if authDelegate.didOfferPassword,
               Self.isExpectedFileVaultDisconnect(mappedError) {
                return LoomSSHBootstrapResult(unlocked: true)
            }
            throw mappedError
        }
    }

    static func timeoutNanoseconds(_ timeout: Duration) -> UInt64 {
        let components = timeout.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let secondNanos = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let fractionalNanos = UInt64(attoseconds / 1_000_000_000)
        if secondNanos.overflow {
            return UInt64.max
        }
        let total = secondNanos.partialValue.addingReportingOverflow(fractionalNanos)
        return total.overflow ? UInt64.max : total.partialValue
    }

    static func shutdownEventLoopGroup(_ group: EventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func mapToBootstrapError(_ error: Error) -> LoomSSHBootstrapError {
        if let error = error as? LoomSSHBootstrapError { return error }

        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout:
                return .timedOut
            default:
                break
            }
        }

        if let ioError = error as? IOError {
            if isAuthenticationPOSIXError(ioError.errnoCode) {
                return .authenticationFailed
            }
            if isTimeoutPOSIXError(ioError.errnoCode) {
                return .timedOut
            }
            return .connectionFailed(ioError.localizedDescription)
        }

        if let sshError = error as? NIOSSHError,
           sshError.type == .invalidUserAuthSignature {
            return .authenticationFailed
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            let code = CInt(nsError.code)
            if isAuthenticationPOSIXError(code) {
                return .authenticationFailed
            }
            if isTimeoutPOSIXError(code) {
                return .timedOut
            }
        }

        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorTimedOut {
                return .timedOut
            }
            if nsError.code == NSURLErrorUserAuthenticationRequired ||
                nsError.code == NSURLErrorUserCancelledAuthentication {
                return .authenticationFailed
            }
        }

        return .connectionFailed(nsError.localizedDescription)
    }

    static func isExpectedFileVaultDisconnect(_ error: LoomSSHBootstrapError) -> Bool {
        switch error {
        case .connectionFailed:
            return true
        case .unsupported, .authenticationFailed, .timedOut, .invalidEndpoint, .invalidServerTrustConfiguration:
            return false
        }
    }

    static func isAuthenticationPOSIXError(_ code: CInt) -> Bool {
        guard let posix = POSIXErrorCode(rawValue: code) else { return false }
        switch posix {
        case .EACCES, .EPERM:
            return true
        default:
            return false
        }
    }

    static func isTimeoutPOSIXError(_ code: CInt) -> Bool {
        if let posix = POSIXErrorCode(rawValue: code), posix == .ETIMEDOUT {
            return true
        }
        return false
    }
}

private final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trustValidator: LoomSSHServerTrustValidator

    init(trustValidator: LoomSSHServerTrustValidator) {
        self.trustValidator = trustValidator
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            _ = try trustValidator.validate(hostKey: hostKey)
            validationCompletePromise.succeed(())
        } catch {
            let mappedError: LoomSSHBootstrapError
            if let trustError = error as? LoomSSHServerTrustError {
                mappedError = .connectionFailed(trustError.localizedDescription)
            } else {
                mappedError = .connectionFailed(error.localizedDescription)
            }
            validationCompletePromise.fail(mappedError)
        }
    }
}

private final class SinglePasswordAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var password: String?
    private let lock = NIOLock()
    private var offeredPassword = false

    var didOfferPassword: Bool {
        lock.withLock { offeredPassword }
    }

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(LoomSSHBootstrapError.authenticationFailed)
            return
        }

        lock.withLock {
            if offeredPassword {
                password = nil
                nextChallengePromise.fail(LoomSSHBootstrapError.authenticationFailed)
            } else {
                guard let password else {
                    nextChallengePromise.fail(LoomSSHBootstrapError.authenticationFailed)
                    return
                }
                offeredPassword = true
                self.password = nil
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: .password(.init(password: password))
                    )
                )
            }
        }
    }
}
#endif
