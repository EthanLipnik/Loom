//
//  LoomHolePunch.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/17/26.
//
//  UDP hole-punch utility for NAT traversal.
//

#if canImport(Network)
import Foundation
import Network
import os

/// Sends small UDP packets to a remote endpoint from a specific local port,
/// opening a NAT binding that allows the remote peer to reach back.
public enum LoomHolePunch {
    /// Sends a burst of UDP hole-punch packets to the given address from the specified local port.
    ///
    /// Each packet is a minimal 4-byte payload — the content is irrelevant, only the NAT binding matters.
    /// Packets are spaced 50ms apart to increase the chance of at least one arriving while the peer's
    /// NAT mapping is active.
    ///
    /// - Parameters:
    ///   - localPort: The local UDP port to send from.
    ///   - address: The remote peer's STUN-mapped public IP address.
    ///   - port: The remote peer's STUN-mapped public port.
    ///   - count: Number of packets to send (default 3).
    public static func punch(
        from localPort: UInt16,
        to address: String,
        port: UInt16,
        count: Int = 3
    ) async {
        let host = NWEndpoint.Host(address)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }

        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.any),
            port: NWEndpoint.Port(rawValue: localPort) ?? .any
        )
        params.allowLocalEndpointReuse = true

        let connection = NWConnection(
            host: host,
            port: endpointPort,
            using: params
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // NWConnection state callbacks fire on the GCD concurrent queue and
            // can race (e.g. .ready then .cancelled in quick succession).  Use
            // an atomic flag to guarantee the continuation resumes exactly once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    connection.stateUpdateHandler = nil
                    let alreadyResumed = resumed.withLock { done -> Bool in
                        if done { return true }
                        done = true
                        return false
                    }
                    if !alreadyResumed {
                        continuation.resume()
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        guard case .ready = connection.state else {
            connection.cancel()
            return
        }

        // Small punch payload — content doesn't matter, only the NAT binding.
        let payload = Data([0x4C, 0x4F, 0x4F, 0x4D]) // "LOOM"

        for i in 0..<count {
            connection.send(
                content: payload,
                completion: .contentProcessed { _ in }
            )
            if i < count - 1 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Brief delay to let the last packet leave, then tear down.
        try? await Task.sleep(for: .milliseconds(100))
        connection.cancel()
    }

    /// Sends hole-punch bursts to multiple candidates.
    public static func punchAll(
        from localPort: UInt16,
        candidates: [LoomRemoteCandidate],
        count: Int = 3
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for candidate in candidates where candidate.transport.usesDatagramPath {
                group.addTask {
                    await punch(
                        from: localPort,
                        to: candidate.address,
                        port: candidate.port,
                        count: count
                    )
                }
            }
        }
    }

    /// Sends hole-punch packets continuously until the returned task is cancelled.
    ///
    /// Each iteration sends a burst of packets to every datagram candidate, then
    /// sleeps for `interval` before repeating.  Cancel the returned task to stop.
    ///
    /// - Parameters:
    ///   - localPort: The local UDP port to send from.
    ///   - candidates: Remote peer candidates to punch toward.
    ///   - interval: Time between bursts (default 500 ms).
    ///   - burstCount: Packets per candidate per burst (default 2).
    /// - Returns: A cancellable task that runs until cancelled.
    public static func punchContinuously(
        from localPort: UInt16,
        candidates: [LoomRemoteCandidate],
        interval: Duration = .milliseconds(500),
        burstCount: Int = 2
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await punchAll(
                    from: localPort,
                    candidates: candidates,
                    count: burstCount
                )
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: interval)
            }
        }
    }
}

#endif
