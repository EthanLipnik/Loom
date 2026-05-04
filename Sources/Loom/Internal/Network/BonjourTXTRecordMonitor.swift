//
//  BonjourTXTRecordMonitor.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/12/26.
//

import Foundation
import Network

struct BonjourServiceIdentity: Hashable {
    let name: String
    let type: String
    let domain: String

    init(name: String, type: String, domain: String) {
        self.name = name
        self.type = Self.normalize(type, defaultValue: "")
        self.domain = Self.normalize(domain, defaultValue: "local")
    }

    init?(endpoint: NWEndpoint) {
        guard case let .service(name, type, domain, _) = endpoint else {
            return nil
        }
        self.init(name: name, type: type, domain: domain)
    }

    init(service: NetService) {
        self.init(name: service.name, type: service.type, domain: service.domain)
    }

    private static func normalize(_ value: String, defaultValue: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized.isEmpty ? defaultValue : normalized
    }
}

final class BonjourTXTRecordMonitor: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    var onTXTRecordChanged: (@MainActor (BonjourServiceIdentity, [String: String]) -> Void)?
    var onServiceResolved: (@MainActor (BonjourServiceIdentity, [NWEndpoint.Host]) -> Void)?
    var onServiceRemoved: (@MainActor (BonjourServiceIdentity) -> Void)?

    private let serviceType: String
    private let enablePeerToPeer: Bool
    // MainActor callers request start/stop without blocking on the monitor thread's QoS.
    private let stateQueue = DispatchQueue(label: "com.mirage.loom.bonjour-txt-monitor.state")

    private var browser: NetServiceBrowser?
    private var workerThread: Thread?
    private var monitorRunLoop: CFRunLoop?
    private var shouldStopWorker = false
    private var didStopOnMonitorThread = false
    private var didFinishWorkerThread = true
    private var servicesByIdentity: [BonjourServiceIdentity: NetService] = [:]
    private var stopCompletions: [@Sendable () -> Void] = []

    init(serviceType: String, enablePeerToPeer: Bool) {
        self.serviceType = serviceType
        self.enablePeerToPeer = enablePeerToPeer
        super.init()
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self, self.workerThread == nil else {
                return
            }

            self.shouldStopWorker = false
            self.didStopOnMonitorThread = false
            self.didFinishWorkerThread = false
            let thread = Thread(target: self, selector: #selector(Self.runMonitorThread), object: nil)
            thread.name = "Loom Bonjour TXT monitor"
            self.workerThread = thread

            thread.start()
        }
    }

    func stop(onStopped: (@Sendable () -> Void)? = nil) {
        stateQueue.async { [self] in
            if let onStopped {
                stopCompletions.append(onStopped)
            }
            self.shouldStopWorker = true

            guard let thread = self.workerThread else {
                let completions = self.drainStopCompletionsOnStateQueue()
                completions.forEach { $0() }
                return
            }

            if thread.isFinished {
                self.didFinishWorkerThread = true
                self.clearWorkerReferencesOnStateQueue()
                let completions = self.drainStopCompletionsOnStateQueue()
                completions.forEach { $0() }
                return
            }

            guard let runLoop = self.monitorRunLoop else {
                return
            }

            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                self.stopOnMonitorThread()
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    @objc private func runMonitorThread() {
        autoreleasepool {
            defer {
                finishWorkerThread()
            }

            let runLoop = RunLoop.current
            let cfRunLoop = CFRunLoopGetCurrent()

            let shouldStop = stateQueue.sync {
                if shouldStopWorker {
                    return true
                }
                monitorRunLoop = cfRunLoop
                return false
            }
            if shouldStop {
                return
            }

            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.includesPeerToPeer = enablePeerToPeer
            browser.schedule(in: runLoop, forMode: .default)
            self.browser = browser
            browser.searchForServices(ofType: serviceType, inDomain: "")

            while shouldContinueRunning {
                _ = autoreleasepool {
                    runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
                }
            }

            stopOnMonitorThread()
        }
    }

    @objc private func stopOnMonitorThread() {
        let shouldStop = stateQueue.sync {
            guard !didStopOnMonitorThread else {
                return false
            }
            didStopOnMonitorThread = true
            shouldStopWorker = true
            return true
        }
        guard shouldStop else {
            return
        }

        let runLoop = RunLoop.current
        browser?.stop()
        browser?.remove(from: runLoop, forMode: .default)
        browser?.delegate = nil
        browser = nil

        for service in servicesByIdentity.values {
            service.stopMonitoring()
            service.stop()
            service.remove(from: runLoop, forMode: .default)
            service.delegate = nil
        }
        servicesByIdentity.removeAll()

        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private func finishWorkerThread() {
        let completions = stateQueue.sync {
            didFinishWorkerThread = true
            clearWorkerReferencesOnStateQueue()
            return drainStopCompletionsOnStateQueue()
        }
        for completion in completions {
            completion()
        }
    }

    private func clearWorkerReferencesOnStateQueue() {
        workerThread = nil
        monitorRunLoop = nil
    }

    private func drainStopCompletionsOnStateQueue() -> [@Sendable () -> Void] {
        let completions = stopCompletions
        stopCompletions.removeAll()
        return completions
    }

    private var shouldContinueRunning: Bool {
        stateQueue.sync {
            !shouldStopWorker
        }
    }

    package var hasFinishedWorkerThreadForTesting: Bool {
        stateQueue.sync {
            didFinishWorkerThread
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let identity = BonjourServiceIdentity(service: service)
        if let existingService = servicesByIdentity[identity], existingService !== service {
            existingService.stopMonitoring()
            existingService.stop()
            existingService.remove(from: RunLoop.current, forMode: .default)
            existingService.delegate = nil
        }

        servicesByIdentity[identity] = service
        service.delegate = self
        service.includesPeerToPeer = enablePeerToPeer
        service.schedule(in: RunLoop.current, forMode: .default)
        service.resolve(withTimeout: 5)
        service.startMonitoring()

        if let txtData = service.txtRecordData() {
            publishTXTRecord(from: service, data: txtData)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let identity = BonjourServiceIdentity(service: service)
        servicesByIdentity.removeValue(forKey: identity)
        service.stopMonitoring()
        service.stop()
        service.remove(from: RunLoop.current, forMode: .default)
        service.delegate = nil

        Task { @MainActor [onServiceRemoved] in
            onServiceRemoved?(identity)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let identity = BonjourServiceIdentity(service: sender)
        let hosts = Self.resolvedHosts(from: sender)
        if !hosts.isEmpty {
            Task { @MainActor [onServiceResolved] in
                onServiceResolved?(identity, hosts)
            }
        }

        guard let txtData = sender.txtRecordData() else {
            return
        }
        publishTXTRecord(from: sender, data: txtData)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        publishTXTRecord(from: sender, data: data)
    }

    private func publishTXTRecord(from service: NetService, data: Data) {
        let identity = BonjourServiceIdentity(service: service)
        let txtRecord = Self.decodeTXTRecord(data)
        Task { @MainActor [onTXTRecordChanged] in
            onTXTRecordChanged?(identity, txtRecord)
        }
    }

    private static func decodeTXTRecord(_ data: Data) -> [String: String] {
        NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, entry in
            guard let value = String(data: entry.value, encoding: .utf8) else {
                return
            }
            result[entry.key] = value
        }
    }

    /// Extracts resolved IP addresses from a `NetService`'s address list,
    /// preferring IPv4 addresses first.
    private static func resolvedHosts(from service: NetService) -> [NWEndpoint.Host] {
        guard let addresses = service.addresses, !addresses.isEmpty else {
            return []
        }

        var ipv4Hosts: [NWEndpoint.Host] = []
        var ipv6Hosts: [NWEndpoint.Host] = []

        for addressData in addresses {
            addressData.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                switch Int32(family) {
                case AF_INET:
                    let addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                    var sin_addr = addr.sin_addr
                    let data = Data(bytes: &sin_addr, count: MemoryLayout<in_addr>.size)
                    if let ipv4 = IPv4Address(data) {
                        ipv4Hosts.append(.ipv4(ipv4))
                    }
                case AF_INET6:
                    let addr = base.assumingMemoryBound(to: sockaddr_in6.self).pointee
                    var sin6_addr = addr.sin6_addr
                    let data = Data(bytes: &sin6_addr, count: MemoryLayout<in6_addr>.size)
                    if let ipv6 = IPv6Address(data) {
                        ipv6Hosts.append(.ipv6(ipv6))
                    }
                default:
                    break
                }
            }
        }

        return ipv4Hosts + ipv6Hosts
    }
}
