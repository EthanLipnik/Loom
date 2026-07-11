//
//  LoomNATPortMapping.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//
//  Requests a NAT port mapping from the router using NAT-PMP / PCP via the
//  system dnssd API.  When the router supports it, this provides a stable
//  external port that doesn't change — far more reliable than STUN for
//  hosts behind aggressive or symmetric NATs.
//

#if canImport(dnssd)
import Foundation
import dnssd

/// Result of a successful NAT port mapping.
public struct LoomNATPortMappingResult: Sendable {
    /// The router's external (public) IPv4 address.
    public let externalAddress: String
    /// The external port mapped to our internal port.
    public let externalPort: UInt16
    /// The internal (local) port that was mapped.
    public let internalPort: UInt16
    /// How long the mapping is valid, in seconds.  The mapping is
    /// automatically renewed before it expires.
    public let ttlSeconds: UInt32
}

/// Requests and maintains a NAT-PMP / PCP port mapping for a local UDP port.
///
/// Usage:
/// ```swift
/// let mapping = LoomNATPortMapping()
/// if let result = await mapping.start(localPort: 62434) {
///     print("Mapped \(result.externalAddress):\(result.externalPort)")
/// }
/// // ... later ...
/// mapping.stop()
/// ```
public final class LoomNATPortMapping: @unchecked Sendable {
    private let lock = NSLock()
    private var serviceRef: DNSServiceRef?
    private var dispatchSource: DispatchSourceRead?
    private var _latestMapping: LoomNATPortMappingResult?
    private var mappingContinuation: CheckedContinuation<LoomNATPortMappingResult?, Never>?

    /// The most recent mapping result, or `nil` if unavailable.
    public var latestMapping: LoomNATPortMappingResult? {
        lock.withLock { _latestMapping }
    }

    public init() {}

    /// Requests a UDP port mapping and waits for the first result.
    ///
    /// Returns `nil` if the router does not support NAT-PMP/PCP or the
    /// mapping times out after 5 seconds.  The mapping remains active and
    /// automatically renews until ``stop()`` is called.
    ///
    /// - Parameter localPort: The internal UDP port to map.
    /// - Returns: The mapping result, or `nil` on failure/unsupported.
    public func start(localPort: UInt16) async -> LoomNATPortMappingResult? {
        stop()

        var ref: DNSServiceRef?

        let callbackContext = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceNATPortMappingCreate(
            &ref,
            0,                      // flags
            0,                      // interfaceIndex (all interfaces)
            UInt32(kDNSServiceProtocol_UDP),
            htons(localPort),       // internal port (network byte order)
            htons(localPort),       // requested external port (network byte order)
            0,                      // ttl (0 = let the system choose)
            natPortMappingCallback,
            callbackContext
        )

        guard err == kDNSServiceErr_NoError, let ref else {
            LoomLogger.log(.transport, "NAT-PMP mapping request failed: \(err)")
            return nil
        }

        lock.withLock { serviceRef = ref }

        // Process callbacks on a background dispatch source.
        let fd = DNSServiceRefSockFD(ref)
        guard fd >= 0 else {
            DNSServiceRefDeallocate(ref)
            lock.withLock { serviceRef = nil }
            return nil
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let currentRef = self.lock.withLock { self.serviceRef }
            guard let currentRef else { return }
            DNSServiceProcessResult(currentRef)
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            let refToRelease = self.lock.withLock { () -> DNSServiceRef? in
                let r = self.serviceRef
                self.serviceRef = nil
                return r
            }
            if let refToRelease {
                DNSServiceRefDeallocate(refToRelease)
            }
        }
        lock.withLock { dispatchSource = source }
        source.resume()

        // Wait for the first mapping result (or timeout).
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<LoomNATPortMappingResult?, Never>) in
            lock.withLock { mappingContinuation = continuation }

            Task {
                try? await Task.sleep(for: .seconds(5))
                let pending = self.lock.withLock { () -> CheckedContinuation<LoomNATPortMappingResult?, Never>? in
                    let c = self.mappingContinuation
                    self.mappingContinuation = nil
                    return c
                }
                pending?.resume(returning: nil)
            }
        }

        return result
    }

    /// Tears down the port mapping.
    public func stop() {
        let (source, pending) = lock.withLock { () -> (DispatchSourceRead?, CheckedContinuation<LoomNATPortMappingResult?, Never>?) in
            let s = dispatchSource
            let c = mappingContinuation
            dispatchSource = nil
            mappingContinuation = nil
            _latestMapping = nil
            return (s, c)
        }
        source?.cancel() // cancel handler deallocates the service ref
        pending?.resume(returning: nil)
    }

    fileprivate func handleMappingResult(
        externalAddress: String,
        externalPort: UInt16,
        internalPort: UInt16,
        ttlSeconds: UInt32
    ) {
        guard externalPort != 0 else { return } // port 0 means mapping failed

        let result = LoomNATPortMappingResult(
            externalAddress: externalAddress,
            externalPort: externalPort,
            internalPort: internalPort,
            ttlSeconds: ttlSeconds
        )

        let continuation = lock.withLock { () -> CheckedContinuation<LoomNATPortMappingResult?, Never>? in
            _latestMapping = result
            let c = mappingContinuation
            mappingContinuation = nil
            return c
        }
        continuation?.resume(returning: result)
    }

    deinit {
        let source = lock.withLock { dispatchSource }
        source?.cancel()
    }
}

// MARK: - C callback

private func natPortMappingCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ externalAddress: UInt32,     // IPv4 in network byte order
    _ protocol: DNSServiceProtocol,
    _ internalPort: UInt16,        // network byte order
    _ externalPort: UInt16,        // network byte order
    _ ttl: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    guard errorCode == kDNSServiceErr_NoError, let context else { return }

    let mapping = Unmanaged<LoomNATPortMapping>.fromOpaque(context).takeUnretainedValue()

    let addressBytes = withUnsafeBytes(of: externalAddress) { Array($0) }
    let addressString = addressBytes.map(String.init).joined(separator: ".")

    mapping.handleMappingResult(
        externalAddress: addressString,
        externalPort: ntohs(externalPort),
        internalPort: ntohs(internalPort),
        ttlSeconds: ttl
    )
}

// MARK: - Byte order helpers

private func htons(_ value: UInt16) -> UInt16 {
    value.bigEndian
}

private func ntohs(_ value: UInt16) -> UInt16 {
    UInt16(bigEndian: value)
}

#endif
