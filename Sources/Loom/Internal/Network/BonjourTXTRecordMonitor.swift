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

final class BonjourTXTRecordMonitor: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onTXTRecordChanged: (@MainActor (BonjourServiceIdentity, [String: String]) -> Void)?
    var onServiceRemoved: (@MainActor (BonjourServiceIdentity) -> Void)?

    private let browser = NetServiceBrowser()
    private let serviceType: String
    private let enablePeerToPeer: Bool

    private var servicesByIdentity: [BonjourServiceIdentity: NetService] = [:]

    init(serviceType: String, enablePeerToPeer: Bool) {
        self.serviceType = serviceType
        self.enablePeerToPeer = enablePeerToPeer
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = enablePeerToPeer
    }

    func start() {
        browser.searchForServices(ofType: serviceType, inDomain: "")
    }

    func stop() {
        browser.stop()
        for service in servicesByIdentity.values {
            service.stopMonitoring()
            service.stop()
            service.delegate = nil
        }
        servicesByIdentity.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let identity = BonjourServiceIdentity(service: service)
        if let existingService = servicesByIdentity[identity], existingService !== service {
            existingService.stopMonitoring()
            existingService.stop()
            existingService.delegate = nil
        }

        servicesByIdentity[identity] = service
        service.delegate = self
        service.includesPeerToPeer = enablePeerToPeer
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
        service.delegate = nil

        Task { @MainActor [onServiceRemoved] in
            onServiceRemoved?(identity)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
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
}
