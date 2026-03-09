//
//  BonjourBrowser.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network
import Observation
import CryptoKit

/// Discovers Loom peers on the local network via Bonjour.
@Observable
@MainActor
public final class LoomDiscovery {
    /// Discovered peers on the network.
    public private(set) var discoveredPeers: [LoomPeer] = []

    /// Whether discovery is currently active
    public private(set) var isSearching: Bool = false

    /// Whether peer-to-peer WiFi discovery is enabled
    public var enablePeerToPeer: Bool = true

    /// Callback invoked whenever discovered peers change.
    public var onPeersChanged: (([LoomPeer]) -> Void)?

    /// Additional peer-change observers keyed by registration token.
    private var peersChangedObservers: [UUID: ([LoomPeer]) -> Void] = [:]

    private var browser: NWBrowser?
    private let serviceType: String
    private var peersByEndpoint: [NWEndpoint: LoomPeer] = [:]

    public init(serviceType: String = Loom.serviceType, enablePeerToPeer: Bool = true) {
        self.serviceType = serviceType
        self.enablePeerToPeer = enablePeerToPeer
    }

    /// Start discovery on the local network.
    public func startDiscovery() {
        guard !isSearching else {
            LoomLogger.discovery("Already searching")
            return
        }

        LoomLogger.discovery("Starting discovery for \(serviceType)")

        let parameters = NWParameters()
        parameters.includePeerToPeer = enablePeerToPeer

        browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )

        browser?.stateUpdateHandler = { [weak self] state in
            LoomLogger.discovery("Browser state: \(state)")
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            LoomLogger.discovery("Results changed: \(results.count) hosts, \(changes.count) changes")
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results, changes: changes)
            }
        }

        browser?.start(queue: .main)
        isSearching = true
    }

    /// Stop discovery.
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isSearching = true
        case .cancelled,
             .failed:
            isSearching = false
        default:
            break
        }
    }

    private func handleBrowseResults(_: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case let .added(result):
                addPeer(from: result)
            case let .removed(result):
                removePeer(for: result.endpoint)
            case let .changed(old, new, _):
                removePeer(for: old.endpoint)
                addPeer(from: new)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func addPeer(from result: NWBrowser.Result) {
        var peerName = "Unknown Peer"
        var advertisement = LoomPeerAdvertisement()
        var txtDict: [String: String] = [:]

        if case let .service(name, _, _, _) = result.endpoint {
            peerName = name
        }

        let metadata = result.metadata
        if case let .bonjour(txtRecord) = metadata {
            for key in txtRecord.dictionary.keys {
                if let value = txtRecord.dictionary[key] { txtDict[key] = value }
            }
            advertisement = LoomPeerAdvertisement.from(txtRecord: txtDict)
            LoomLogger.discovery(
                "Peer metadata \(peerName): did=\(advertisement.deviceID?.uuidString ?? "nil") type=\(advertisement.deviceType?.rawValue ?? "unknown") keys=\(txtDict.keys.sorted())"
            )
        }

        let peerID = advertisement.deviceID ?? fallbackPeerID(endpoint: result.endpoint, peerName: peerName)

        let peer = LoomPeer(
            id: peerID,
            name: peerName,
            deviceType: advertisement.deviceType ?? .unknown,
            endpoint: result.endpoint,
            advertisement: advertisement
        )

        peersByEndpoint[result.endpoint] = peer
        updatePeersList()
    }

    private func fallbackPeerID(endpoint: NWEndpoint, peerName: String) -> UUID {
        let source = "\(peerName)|\(endpoint.debugDescription)"
        let digest = SHA256.hash(data: Data(source.utf8))
        let bytes = Array(digest)
        var uuidBytes = Array(bytes.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80

        let uuid = uuid_t(
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )
        return UUID(uuid: uuid)
    }

    private func removePeer(for endpoint: NWEndpoint) {
        peersByEndpoint.removeValue(forKey: endpoint)
        updatePeersList()
    }

    private func updatePeersList() {
        discoveredPeers = Array(peersByEndpoint.values).sorted { $0.name < $1.name }
        notifyPeersChanged()
    }

    /// Force a discovery refresh.
    public func refresh() {
        stopDiscovery()
        peersByEndpoint.removeAll()
        discoveredPeers.removeAll()
        notifyPeersChanged()
        startDiscovery()
    }

    /// Registers an observer that is invoked whenever discovered peers change.
    @discardableResult
    public func addPeersChangedObserver(_ observer: @escaping ([LoomPeer]) -> Void) -> UUID {
        let token = UUID()
        peersChangedObservers[token] = observer
        return token
    }

    /// Removes a previously-registered peer-change observer.
    public func removePeersChangedObserver(_ token: UUID) {
        peersChangedObservers.removeValue(forKey: token)
    }

    private func notifyPeersChanged() {
        onPeersChanged?(discoveredPeers)
        for observer in peersChangedObservers.values {
            observer(discoveredPeers)
        }
    }
}
