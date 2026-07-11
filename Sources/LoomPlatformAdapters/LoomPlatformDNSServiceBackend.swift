//
//  LoomPlatformDNSServiceBackend.swift
//  LoomPlatformAdapters
//
//  Created by Ethan Lipnik on 7/10/26.
//

import CLoomPlatformSupport
import Foundation
import LoomNetworking

public final class LoomPlatformDNSServiceBackend: LoomDNSServiceBackend, Sendable {
    public init() {}

    public func makeBrowser(
        configuration: LoomDNSServiceConfiguration
    ) throws -> any LoomDNSServiceBrowser {
        LoomPlatformDNSServiceBrowser(configuration: configuration)
    }

    public func makeAdvertiser(
        identity: LoomDNSServiceIdentity,
        hostName: String?,
        port: UInt16,
        txtRecord: LoomTXTRecord
    ) throws -> any LoomDNSServiceAdvertiser {
        LoomPlatformDNSServiceAdvertiser(
            identity: identity,
            hostName: hostName,
            port: port,
            txtRecord: txtRecord
        )
    }
}

private struct LoomPlatformDNSServiceSnapshot: Sendable {
    let instanceName: String
    let hostName: String?
    let eventSequence: UInt64
    let port: UInt16
    let interfaceIndex: UInt32?
    let ttl: UInt32
    let addresses: [LoomNetworkHost]
    let properties: [(String, String)]
}

private enum LoomPlatformDNSCallbackEvent: Sendable {
    case ready
    case resolved(LoomPlatformDNSServiceSnapshot)
    case removed(instanceName: String, interfaceIndex: UInt32?, eventSequence: UInt64)
    case failed(UInt32)
    case cancelled
}

private final class LoomPlatformDNSBrowserCallbackBox: @unchecked Sendable {
    let queue = LoomPlatformCallbackQueue()
    let handler: @Sendable (LoomPlatformDNSCallbackEvent) async -> Void

    init(handler: @escaping @Sendable (LoomPlatformDNSCallbackEvent) async -> Void) {
        self.handler = handler
    }
}

private final class LoomPlatformDNSAdvertiserCallbackBox: @unchecked Sendable {
    let queue = LoomPlatformCallbackQueue()
    let handler: @Sendable (UInt32) async -> Void

    init(handler: @escaping @Sendable (UInt32) async -> Void) {
        self.handler = handler
    }
}

private func loomPlatformReleaseCallbackContext(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<AnyObject>.fromOpaque(context).release()
}

private func loomPlatformDNSBrowserCallback(
    _ kind: loom_dnssd_event_kind,
    _ status: UInt32,
    _ result: UnsafePointer<loom_dnssd_service_result>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<LoomPlatformDNSBrowserCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let event: LoomPlatformDNSCallbackEvent
    switch kind {
    case LOOM_DNSSD_EVENT_READY:
        event = .ready
    case LOOM_DNSSD_EVENT_ADDED, LOOM_DNSSD_EVENT_CHANGED:
        guard let result,
              let instanceNamePointer = result.pointee.instance_name_utf8 else {
            event = .failed(13)
            break
        }
        let instanceName = String(cString: instanceNamePointer)
        let hostName = result.pointee.host_name_utf8.map(String.init(cString:))
        let interfaceIndex = result.pointee.interface_index == 0
            ? nil
            : result.pointee.interface_index
        var addresses: [LoomNetworkHost] = []
        if let ipv4 = result.pointee.ipv4_address_utf8 {
            addresses.append(LoomNetworkHost(String(cString: ipv4)))
        }
        if let ipv6 = result.pointee.ipv6_address_utf8 {
            var value = String(cString: ipv6)
            if value.lowercased().hasPrefix("fe80:"), let interfaceIndex {
                value += "%\(interfaceIndex)"
            }
            addresses.append(LoomNetworkHost(value))
        }
        var properties: [(String, String)] = []
        let propertyCount = min(Int(result.pointee.property_count), LoomTXTRecord.maximumEntryCount)
        if let keys = result.pointee.property_keys_utf8,
           let values = result.pointee.property_values_utf8 {
            properties.reserveCapacity(propertyCount)
            for index in 0..<propertyCount {
                guard let key = keys[index], let value = values[index] else { continue }
                properties.append((String(cString: key), String(cString: value)))
            }
        }
        event = .resolved(
            LoomPlatformDNSServiceSnapshot(
                instanceName: instanceName,
                hostName: hostName,
                eventSequence: result.pointee.event_sequence,
                port: result.pointee.port,
                interfaceIndex: interfaceIndex,
                ttl: result.pointee.ttl_seconds,
                addresses: addresses,
                properties: properties
            )
        )
    case LOOM_DNSSD_EVENT_REMOVED:
        guard let result,
              let instanceNamePointer = result.pointee.instance_name_utf8 else {
            event = .failed(13)
            break
        }
        event = .removed(
            instanceName: String(cString: instanceNamePointer),
            interfaceIndex: result.pointee.interface_index == 0 ? nil : result.pointee.interface_index,
            eventSequence: result.pointee.event_sequence
        )
    case LOOM_DNSSD_EVENT_CANCELLED:
        event = .cancelled
    default:
        event = .failed(status)
    }
    box.queue.submit {
        await box.handler(event)
    }
}

private func loomPlatformDNSAdvertiserCallback(
    _ status: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<LoomPlatformDNSAdvertiserCallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.queue.submit {
        await box.handler(status)
    }
}

private actor LoomPlatformDNSServiceBrowser: LoomDNSServiceBrowser {
    private let configuration: LoomDNSServiceConfiguration
    private var nativeBrowser: OpaquePointer?
    private var continuations: [UUID: AsyncStream<LoomDNSServiceBrowserEvent>.Continuation] = [:]
    private var services: [LoomDNSServiceIdentity: LoomDNSServiceInstance] = [:]
    private var expiryTasks: [LoomDNSServiceIdentity: Task<Void, Never>] = [:]
    private var resolveLedger = LoomPlatformDNSResolveLedger()
    private var isCancelled = false

    init(configuration: LoomDNSServiceConfiguration) {
        self.configuration = configuration
    }

    func start() throws {
        guard nativeBrowser == nil, !isCancelled else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "DNS-SD browser is already active.")
        }
        let callbackBox = LoomPlatformDNSBrowserCallbackBox { [weak self] event in
            await self?.handle(event)
        }
        let context = Unmanaged.passRetained(callbackBox).toOpaque()
        var errorCode: UInt32 = 0
        let queryName = LoomDNSServiceIdentity(
            name: "",
            type: configuration.serviceType,
            domain: configuration.domain
        ).queryName
        nativeBrowser = queryName.withCString { queryNamePointer in
            loom_dnssd_browser_start(
                queryNamePointer,
                configuration.interfaceIndex ?? 0,
                loomPlatformDNSBrowserCallback,
                context,
                loomPlatformReleaseCallbackContext,
                &errorCode
            )
        }
        guard nativeBrowser != nil else {
            throw Self.error(code: errorCode, operation: "start DNS-SD browse")
        }
    }

    func makeEventStream() -> AsyncStream<LoomDNSServiceBrowserEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: LoomDNSServiceBrowserEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        continuations[id] = continuation
        if isCancelled {
            continuation.yield(.cancelled)
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeContinuation(id) }
        }
        return stream
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll(keepingCapacity: false)
        if let nativeBrowser {
            loom_dnssd_browser_cancel(nativeBrowser)
            loom_dnssd_browser_release(nativeBrowser)
            self.nativeBrowser = nil
        }
        publish(.cancelled)
        finishEvents()
    }

    private func handle(_ event: LoomPlatformDNSCallbackEvent) {
        guard !isCancelled else { return }
        switch event {
        case .ready:
            publish(.ready)
        case let .failed(code):
            publish(.failed(Self.error(code: code, operation: "browse DNS-SD services")))
        case .cancelled:
            cancel()
        case let .removed(instanceName, interfaceIndex, eventSequence):
            guard let parsed = LoomDNSServiceIdentity(
                fullyQualifiedName: instanceName,
                interfaceIndex: interfaceIndex
            ), resolveLedger.acceptRemoval(parsed, eventSequence: eventSequence) else { return }
            let matching = services.keys.filter { identity in
                identity.name == parsed.name && identity.type == parsed.type && identity.domain == parsed.domain &&
                    (parsed.interfaceIndex == nil || identity.interfaceIndex == parsed.interfaceIndex) &&
                    resolveLedger.shouldApplyRemoval(to: identity, eventSequence: eventSequence)
            }
            for identity in matching {
                remove(identity)
            }
        case let .resolved(snapshot):
            guard let identity = LoomDNSServiceIdentity(
                fullyQualifiedName: snapshot.instanceName,
                interfaceIndex: snapshot.interfaceIndex
            ), snapshot.port > 0,
              resolveLedger.acceptResolution(identity, eventSequence: snapshot.eventSequence) else { return }
            do {
                let txtRecord = try LoomTXTRecord(entries: snapshot.properties.map { key, value in
                    try LoomTXTRecord.Entry(key: key, stringValue: value)
                })
                let instance = LoomDNSServiceInstance(
                    identity: identity,
                    hostName: snapshot.hostName,
                    addresses: snapshot.addresses,
                    port: snapshot.port,
                    txtRecord: txtRecord,
                    timeToLive: snapshot.ttl
                )
                let previous = services.updateValue(instance, forKey: identity)
                publish(previous == nil ? .added(instance) : .changed(instance))
                scheduleExpiry(for: identity, ttl: snapshot.ttl)
            } catch {
                publish(.failed(LoomNetworkError(
                    code: .other,
                    detail: "Rejected malformed DNS-SD TXT properties: \(error.localizedDescription)"
                )))
            }
        }
    }

    private func scheduleExpiry(for identity: LoomDNSServiceIdentity, ttl: UInt32) {
        expiryTasks.removeValue(forKey: identity)?.cancel()
        guard ttl > 0 else {
            remove(identity)
            return
        }
        let expected = services[identity]
        expiryTasks[identity] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Int64(ttl)))
            guard !Task.isCancelled, let self else { return }
            await self.expire(identity, expected: expected)
        }
    }

    private func expire(
        _ identity: LoomDNSServiceIdentity,
        expected: LoomDNSServiceInstance?
    ) {
        guard services[identity] == expected else { return }
        remove(identity)
    }

    private func remove(_ identity: LoomDNSServiceIdentity) {
        guard services.removeValue(forKey: identity) != nil else { return }
        expiryTasks.removeValue(forKey: identity)?.cancel()
        publish(.removed(identity))
    }

    private func publish(_ event: LoomDNSServiceBrowserEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func finishEvents() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private nonisolated static func error(code: UInt32, operation: String) -> LoomNetworkError {
        let category: LoomNetworkErrorCode
        switch code {
        case 995, 1_223:
            category = .cancelled
        case 9003:
            category = .unreachable
        case 9005:
            category = .networkDown
        default:
            category = .other
        }
        return LoomNetworkError(code: category, detail: "Could not \(operation) (status \(code)).")
    }
}

struct LoomPlatformDNSResolveLedger {
    private struct ServiceKey: Hashable {
        let name: String
        let type: String
        let domain: String

        init(_ identity: LoomDNSServiceIdentity) {
            name = identity.name
            type = identity.type
            domain = identity.domain
        }
    }

    private struct ScopedServiceKey: Hashable {
        let service: ServiceKey
        let interfaceIndex: UInt32?

        init(_ identity: LoomDNSServiceIdentity) {
            service = ServiceKey(identity)
            interfaceIndex = identity.interfaceIndex
        }
    }

    private var unscopedRemovalSequence: [ServiceKey: UInt64] = [:]
    private var scopedEventSequence: [ScopedServiceKey: UInt64] = [:]

    mutating func acceptResolution(
        _ identity: LoomDNSServiceIdentity,
        eventSequence: UInt64
    ) -> Bool {
        let service = ServiceKey(identity)
        let scoped = ScopedServiceKey(identity)
        let latestSequence = max(
            unscopedRemovalSequence[service] ?? 0,
            scopedEventSequence[scoped] ?? 0
        )
        guard eventSequence >= latestSequence else { return false }
        scopedEventSequence[scoped] = eventSequence
        return true
    }

    mutating func acceptRemoval(
        _ identity: LoomDNSServiceIdentity,
        eventSequence: UInt64
    ) -> Bool {
        let service = ServiceKey(identity)
        if identity.interfaceIndex != nil {
            let scoped = ScopedServiceKey(identity)
            let latestSequence = max(
                unscopedRemovalSequence[service] ?? 0,
                scopedEventSequence[scoped] ?? 0
            )
            guard eventSequence >= latestSequence else { return false }
            scopedEventSequence[scoped] = eventSequence
            return true
        }

        guard eventSequence >= (unscopedRemovalSequence[service] ?? 0) else { return false }
        unscopedRemovalSequence[service] = eventSequence
        scopedEventSequence = scopedEventSequence.filter { entry in
            entry.key.service != service || entry.value > eventSequence
        }
        return true
    }

    func shouldApplyRemoval(
        to identity: LoomDNSServiceIdentity,
        eventSequence: UInt64
    ) -> Bool {
        let scoped = ScopedServiceKey(identity)
        return (scopedEventSequence[scoped] ?? 0) <= eventSequence
    }
}

private actor LoomPlatformDNSServiceAdvertiser: LoomDNSServiceAdvertiser {
    private let identity: LoomDNSServiceIdentity
    private let hostName: String?
    private let port: UInt16
    private var txtRecord: LoomTXTRecord
    private var nativeAdvertiser: OpaquePointer?
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var stopContinuation: CheckedContinuation<Void, any Error>?
    private var isStopping = false
    private var isCancelled = false

    init(
        identity: LoomDNSServiceIdentity,
        hostName: String?,
        port: UInt16,
        txtRecord: LoomTXTRecord
    ) {
        self.identity = identity
        self.hostName = hostName
        self.port = port
        self.txtRecord = txtRecord
    }

    func start() async throws {
        guard nativeAdvertiser == nil, startContinuation == nil, !isCancelled else {
            throw LoomNetworkError(code: .invalidConfiguration, detail: "DNS-SD advertiser is already active.")
        }
        try await startNativeAdvertiser()
    }

    func updateTXTRecord(_ txtRecord: LoomTXTRecord) async throws {
        guard !isCancelled else {
            throw LoomNetworkError(code: .cancelled, detail: "DNS-SD advertiser is cancelled.")
        }
        self.txtRecord = txtRecord
        try await stopNativeAdvertiser()
        try await startNativeAdvertiser()
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        startContinuation?.resume(
            throwing: LoomNetworkError(code: .cancelled, detail: "DNS-SD advertiser cancelled.")
        )
        startContinuation = nil
        try? await stopNativeAdvertiser()
    }

    private func startNativeAdvertiser() async throws {
        try Task.checkCancellation()
        let stringEntries = try txtRecord.entries.map { entry -> (String, String) in
            guard let value = entry.value,
                  let stringValue = String(data: value, encoding: .utf8),
                  !stringValue.contains("\0") else {
                throw LoomNetworkError(
                    code: .invalidConfiguration,
                    detail: "The platform DNS-SD API requires UTF-8 TXT values without NUL bytes."
                )
            }
            return (entry.key, stringValue)
        }
        let allocatedKeys = stringEntries.map { Self.allocateCString($0.0) }
        let allocatedValues = stringEntries.map { Self.allocateCString($0.1) }
        defer {
            allocatedKeys.forEach { $0.deallocate() }
            allocatedValues.forEach { $0.deallocate() }
        }
        let keyPointers = allocatedKeys.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        let valuePointers = allocatedValues.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        let callbackBox = LoomPlatformDNSAdvertiserCallbackBox { [weak self] status in
            await self?.handleNativeStatus(status: status)
        }
        let context = Unmanaged.passRetained(callbackBox).toOpaque()
        var errorCode: UInt32 = 0
        let fullyQualifiedName = identity.fullyQualifiedName
        let interfaceIndex = identity.interfaceIndex ?? 0
        let advertisedHostName = hostName
        let advertisedPort = port
        nativeAdvertiser = fullyQualifiedName.withCString { instanceName in
            let invoke: (UnsafePointer<CChar>?) -> OpaquePointer? = { hostName in
                keyPointers.withUnsafeBufferPointer { keys in
                    valuePointers.withUnsafeBufferPointer { values in
                        loom_dnssd_advertiser_start(
                            instanceName,
                            hostName,
                            advertisedPort,
                            interfaceIndex,
                            stringEntries.count,
                            keys.baseAddress,
                            values.baseAddress,
                            loomPlatformDNSAdvertiserCallback,
                            context,
                            loomPlatformReleaseCallbackContext,
                            &errorCode
                        )
                    }
                }
            }
            if let advertisedHostName {
                return advertisedHostName.withCString(invoke)
            }
            return invoke(nil)
        }
        guard nativeAdvertiser != nil else {
            throw Self.error(code: errorCode)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                startContinuation = continuation
            }
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    private func handleNativeStatus(status: UInt32) {
        if isStopping {
            guard let stopContinuation else { return }
            self.stopContinuation = nil
            isStopping = false
            if status == 0 || status == 995 || status == 1_223 {
                stopContinuation.resume()
            } else {
                stopContinuation.resume(throwing: Self.error(code: status))
            }
            return
        }

        guard let startContinuation else { return }
        self.startContinuation = nil
        if status == 0 {
            startContinuation.resume()
        } else {
            discardNativeAdvertiser()
            startContinuation.resume(throwing: Self.error(code: status))
        }
    }

    private func stopNativeAdvertiser() async throws {
        guard let nativeAdvertiser else { return }
        isStopping = true
        var errorCode: UInt32 = 0
        let awaitsCallback = loom_dnssd_advertiser_stop(nativeAdvertiser, &errorCode)
        loom_dnssd_advertiser_release(nativeAdvertiser)
        self.nativeAdvertiser = nil
        guard awaitsCallback != 0 else {
            isStopping = false
            if errorCode != 0 {
                throw Self.error(code: errorCode)
            }
            return
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            stopContinuation = continuation
        }
    }

    private func discardNativeAdvertiser() {
        guard let nativeAdvertiser else { return }
        var ignoredError: UInt32 = 0
        _ = loom_dnssd_advertiser_stop(nativeAdvertiser, &ignoredError)
        loom_dnssd_advertiser_release(nativeAdvertiser)
        self.nativeAdvertiser = nil
    }

    private nonisolated static func allocateCString(_ string: String) -> UnsafeMutablePointer<CChar> {
        let bytes = string.utf8CString
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        for (index, byte) in bytes.enumerated() {
            pointer.advanced(by: index).initialize(to: byte)
        }
        return pointer
    }

    private nonisolated static func error(code: UInt32) -> LoomNetworkError {
        let collisionCodes: Set<UInt32> = [52, 9006, 9007, 9711]
        return LoomNetworkError(
            code: collisionCodes.contains(code) ? .invalidConfiguration : .other,
            detail: collisionCodes.contains(code)
                ? "DNS-SD service name collides with an existing registration (status \(code))."
                : "DNS-SD service registration failed (status \(code))."
        )
    }
}

private final class LoomPlatformCallbackQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        let task = Task {
            if let previous {
                await previous.value
            }
            await operation()
        }
        tail = task
        lock.unlock()
    }
}
