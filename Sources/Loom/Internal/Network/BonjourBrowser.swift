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

    /// Whether Bonjour discovery is enabled.
    public var enableBonjour: Bool = true

    /// Optional local device identifier used to filter self from discovery results.
    public var localDeviceID: UUID?

    /// Callback invoked whenever discovered peers change.
    public var onPeersChanged: (([LoomPeer]) -> Void)?

    /// Additional peer-change observers keyed by registration token.
    private var peersChangedObservers: [UUID: ([LoomPeer]) -> Void] = [:]

    private var browser: NWBrowser?
    private var txtRecordMonitor: BonjourTXTRecordMonitor?
    private let serviceType: String
    private var browseResultsByEndpoint: [NWEndpoint: NWBrowser.Result] = [:]
    private var txtRecordsByService: [BonjourServiceIdentity: [String: String]] = [:]
    private var resolvedAddressesByService: [BonjourServiceIdentity: [NWEndpoint.Host]] = [:]
    private var peerCandidatesByDeviceID: [UUID: [NWEndpoint: LoomHostDiscoveryCandidate]] = [:]
    private var peerIDByEndpoint: [NWEndpoint: UUID] = [:]
    private var peersByID: [LoomPeerID: LoomPeer] = [:]

    public init(
        serviceType: String = Loom.serviceType,
        enableBonjour: Bool = true,
        enablePeerToPeer: Bool = true,
        localDeviceID: UUID? = nil
    ) {
        self.serviceType = serviceType
        self.enableBonjour = enableBonjour
        self.enablePeerToPeer = enablePeerToPeer
        self.localDeviceID = localDeviceID
    }

    /// Start discovery on the local network.
    public func startDiscovery() {
        guard enableBonjour else {
            LoomLogger.discovery("Bonjour discovery disabled by configuration")
            stopDiscovery()
            return
        }

        guard !isSearching else {
            LoomLogger.discovery("Already searching")
            return
        }

        validateBonjourInfoPlistKeys(serviceType: serviceType)

        LoomLogger.discovery("Starting discovery for \(serviceType)")

        let parameters = Self.makeBrowserParameters(enablePeerToPeer: enablePeerToPeer)

        let txtRecordMonitor = BonjourTXTRecordMonitor(
            serviceType: serviceType,
            enablePeerToPeer: enablePeerToPeer
        )
        txtRecordMonitor.onTXTRecordChanged = { [weak self] serviceIdentity, txtRecord in
            self?.handleTXTRecordUpdate(txtRecord, for: serviceIdentity)
        }
        txtRecordMonitor.onServiceResolved = { [weak self] serviceIdentity, hosts in
            self?.handleServiceResolved(hosts, for: serviceIdentity)
        }
        txtRecordMonitor.onServiceRemoved = { [weak self] serviceIdentity in
            self?.handleTXTRecordRemoval(for: serviceIdentity)
        }
        txtRecordMonitor.start()
        self.txtRecordMonitor = txtRecordMonitor

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

    nonisolated package static func makeBrowserParameters(enablePeerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = enablePeerToPeer
        return parameters
    }

    /// Stop discovery.
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        txtRecordMonitor?.stop()
        txtRecordMonitor = nil
        isSearching = false
        browseResultsByEndpoint.removeAll()
        txtRecordsByService.removeAll()
        resolvedAddressesByService.removeAll()
        peerCandidatesByDeviceID.removeAll()
        peerIDByEndpoint.removeAll()
        peersByID.removeAll()
        discoveredPeers.removeAll()
        notifyPeersChanged()
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
                browseResultsByEndpoint[result.endpoint] = result
                addPeer(from: result)
            case let .removed(result):
                browseResultsByEndpoint.removeValue(forKey: result.endpoint)
                removePeer(for: result.endpoint)
            case let .changed(old, new, _):
                browseResultsByEndpoint.removeValue(forKey: old.endpoint)
                removePeer(for: old.endpoint)
                browseResultsByEndpoint[new.endpoint] = new
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

        if case let .service(name, _, _, _) = result.endpoint {
            peerName = name
        }

        let resolvedAddresses: [NWEndpoint.Host]
        if let serviceIdentity = BonjourServiceIdentity(endpoint: result.endpoint) {
            resolvedAddresses = resolvedAddressesByService[serviceIdentity] ?? []
        } else {
            resolvedAddresses = []
        }

        upsertBonjourPeer(
            peerName: peerName,
            endpoint: result.endpoint,
            txtRecord: txtRecord(for: result),
            resolvedAddresses: resolvedAddresses
        )
    }

    private func upsertBonjourPeer(
        peerName: String,
        endpoint: NWEndpoint,
        txtRecord: [String: String],
        resolvedAddresses: [NWEndpoint.Host] = []
    ) {
        let advertisement = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        if !txtRecord.isEmpty {
            LoomLogger.discovery(
                "Peer metadata \(peerName): did=\(advertisement.deviceID?.uuidString ?? "nil") type=\(advertisement.deviceType?.rawValue ?? "unknown") keys=\(txtRecord.keys.sorted())"
            )
        }

        let peerID = advertisement.deviceID ?? fallbackPeerID(endpoint: endpoint, peerName: peerName)
        guard peerID != localDeviceID else {
            removePeer(for: endpoint)
            return
        }

        let normalizedAdvertisement = LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID ?? peerID,
            identityKeyID: advertisement.identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            hostName: advertisement.hostName,
            directTransports: advertisement.directTransports,
            metadata: advertisement.metadata
        )
        let candidate = LoomHostDiscoveryCandidate(
            name: peerName,
            deviceType: normalizedAdvertisement.deviceType ?? .unknown,
            endpoint: endpoint,
            advertisement: normalizedAdvertisement,
            resolvedAddresses: resolvedAddresses
        )

        storeCandidate(candidate, for: endpoint, peerID: peerID)
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
        guard let peerID = peerIDByEndpoint.removeValue(forKey: endpoint) else {
            return
        }
        removeCandidate(for: endpoint, peerID: peerID)
    }

    private func txtRecord(for result: NWBrowser.Result) -> [String: String] {
        if let serviceIdentity = BonjourServiceIdentity(endpoint: result.endpoint),
           let txtRecord = txtRecordsByService[serviceIdentity] {
            return txtRecord
        }

        guard case let .bonjour(txtRecord) = result.metadata else {
            return [:]
        }

        return txtRecord.dictionary.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value
        }
    }

    private func handleTXTRecordUpdate(_ txtRecord: [String: String], for serviceIdentity: BonjourServiceIdentity) {
        txtRecordsByService[serviceIdentity] = txtRecord
        refreshPeers(for: serviceIdentity)
    }

    private func handleServiceResolved(_ hosts: [NWEndpoint.Host], for serviceIdentity: BonjourServiceIdentity) {
        resolvedAddressesByService[serviceIdentity] = hosts
        LoomLogger.discovery(
            "Service resolved \(serviceIdentity.name): \(hosts.map { "\($0)" }.joined(separator: ", "))"
        )
        refreshPeers(for: serviceIdentity)
    }

    private func handleTXTRecordRemoval(for serviceIdentity: BonjourServiceIdentity) {
        txtRecordsByService.removeValue(forKey: serviceIdentity)
        resolvedAddressesByService.removeValue(forKey: serviceIdentity)
        refreshPeers(for: serviceIdentity)
    }

    private func refreshPeers(for serviceIdentity: BonjourServiceIdentity) {
        let matchingResults = browseResultsByEndpoint.values.filter { result in
            BonjourServiceIdentity(endpoint: result.endpoint) == serviceIdentity
        }
        for result in matchingResults {
            addPeer(from: result)
        }
    }

    private func storeCandidate(
        _ candidate: LoomHostDiscoveryCandidate,
        for endpoint: NWEndpoint,
        peerID: UUID
    ) {
        if let existingPeerID = peerIDByEndpoint[endpoint], existingPeerID != peerID {
            removeCandidate(for: endpoint, peerID: existingPeerID)
        }

        peerIDByEndpoint[endpoint] = peerID
        var candidates = peerCandidatesByDeviceID[peerID] ?? [:]
        candidates[endpoint] = candidate
        peerCandidatesByDeviceID[peerID] = candidates
        updatePeerSelection(forDeviceID: peerID)
    }

    private func removeCandidate(for endpoint: NWEndpoint, peerID: UUID) {
        if var candidates = peerCandidatesByDeviceID[peerID] {
            candidates.removeValue(forKey: endpoint)
            if candidates.isEmpty {
                peerCandidatesByDeviceID.removeValue(forKey: peerID)
                removeProjectedPeers(forDeviceID: peerID)
            } else {
                peerCandidatesByDeviceID[peerID] = candidates
                updatePeerSelection(forDeviceID: peerID)
                return
            }
        }
        updatePeersList()
    }

    private func updatePeersList() {
        discoveredPeers = Array(peersByID.values).sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        notifyPeersChanged()
    }

    /// Force a discovery refresh.
    public func refresh() {
        guard enableBonjour else {
            stopDiscovery()
            return
        }

        stopDiscovery()
        startDiscovery()
    }

    package func upsertPeerForTesting(_ peer: LoomPeer) {
        guard peer.deviceID != localDeviceID else {
            return
        }
        let candidate = LoomHostDiscoveryCandidate(
            name: peer.name,
            deviceType: peer.deviceType,
            endpoint: peer.endpoint,
            advertisement: peer.advertisement.deviceID == nil
                ? LoomPeerAdvertisement(
                    protocolVersion: peer.advertisement.protocolVersion,
                    deviceID: peer.deviceID,
                    identityKeyID: peer.advertisement.identityKeyID,
                    deviceType: peer.advertisement.deviceType,
                    modelIdentifier: peer.advertisement.modelIdentifier,
                    iconName: peer.advertisement.iconName,
                    machineFamily: peer.advertisement.machineFamily,
                    hostName: peer.advertisement.hostName,
                    directTransports: peer.advertisement.directTransports,
                    metadata: peer.advertisement.metadata
                )
                : peer.advertisement,
            resolvedAddresses: peer.resolvedAddresses
        )
        storeCandidate(candidate, for: peer.endpoint, peerID: peer.deviceID)
    }

    package func upsertBonjourPeerForTesting(
        peerName: String,
        endpoint: NWEndpoint,
        txtRecord: [String: String],
        resolvedAddresses: [NWEndpoint.Host] = []
    ) {
        upsertBonjourPeer(
            peerName: peerName,
            endpoint: endpoint,
            txtRecord: txtRecord,
            resolvedAddresses: resolvedAddresses
        )
    }

    package func removePeerForTesting(endpoint: NWEndpoint) {
        removePeer(for: endpoint)
    }

    private func updatePeerSelection(forDeviceID peerID: UUID) {
        guard let candidates = peerCandidatesByDeviceID[peerID], !candidates.isEmpty else {
            removeProjectedPeers(forDeviceID: peerID)
            updatePeersList()
            return
        }
        guard let preferredCandidate = candidates.values.min(by: isPreferredPeer(_:_:)) else {
            removeProjectedPeers(forDeviceID: peerID)
            updatePeersList()
            return
        }

        removeProjectedPeers(forDeviceID: peerID)
        let projections = LoomHostCatalogCodec.projections(
            peerName: preferredCandidate.name,
            advertisement: preferredCandidate.advertisement
        )
        for projection in projections {
            peersByID[projection.peerID] = LoomPeer(
                id: projection.peerID,
                name: projection.displayName,
                deviceType: preferredCandidate.deviceType,
                endpoint: preferredCandidate.endpoint,
                advertisement: projection.advertisement,
                resolvedAddresses: preferredCandidate.resolvedAddresses
            )
        }
        updatePeersList()
    }

    private func isPreferredPeer(_ lhs: LoomHostDiscoveryCandidate, _ rhs: LoomHostDiscoveryCandidate) -> Bool {
        let leftRank = rank(for: lhs)
        let rightRank = rank(for: rhs)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return lhs.endpoint.debugDescription < rhs.endpoint.debugDescription
    }

    private func rank(for peer: LoomHostDiscoveryCandidate) -> Int {
        guard let preferredTransport = peer.advertisement.directTransports.min(by: transportIsPreferred(_:_:)) else {
            return Int.max
        }
        return pathRank(preferredTransport.pathKind) * 10 + transportRank(preferredTransport.transportKind)
    }

    private func removeProjectedPeers(forDeviceID peerID: UUID) {
        peersByID = peersByID.filter { $0.key.deviceID != peerID }
    }

    private func transportIsPreferred(
        _ lhs: LoomDirectTransportAdvertisement,
        _ rhs: LoomDirectTransportAdvertisement
    ) -> Bool {
        let leftRank = pathRank(lhs.pathKind) * 10 + transportRank(lhs.transportKind)
        let rightRank = pathRank(rhs.pathKind) * 10 + transportRank(rhs.transportKind)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return lhs.port < rhs.port
    }

    private func pathRank(_ pathKind: LoomDirectPathKind?) -> Int {
        switch pathKind ?? .other {
        case .wired:
            return 0
        case .wifi:
            return 1
        case .awdl:
            return 2
        case .other:
            return 3
        }
    }

    private func transportRank(_ transportKind: LoomTransportKind) -> Int {
        switch transportKind {
        case .udp:
            return 0
        case .quic:
            return 1
        case .tcp:
            return 2
        }
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

private struct LoomHostDiscoveryCandidate {
    let name: String
    let deviceType: DeviceType
    let endpoint: NWEndpoint
    let advertisement: LoomPeerAdvertisement
    let resolvedAddresses: [NWEndpoint.Host]
}
