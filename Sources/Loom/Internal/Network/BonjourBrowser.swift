//
//  BonjourBrowser.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network
import Observation

/// Discovers Loom peers on the local network via Bonjour.
@Observable
@MainActor
public final class LoomDiscovery {
    /// Discovered peers on the network.
    public private(set) var discoveredPeers: [LoomPeer] = []

    /// Whether discovery is currently active
    public private(set) var isSearching: Bool = false

    /// Whether Bonjour browsing has reached the ready state.
    public private(set) var isBrowserReady: Bool = false

    /// Whether peer-to-peer WiFi discovery is enabled
    public var enablePeerToPeer: Bool = true

    /// Whether Bonjour discovery is enabled.
    public var enableBonjour: Bool = true

    /// Policy used to rank discovered direct transports for the same device.
    public var directConnectionPolicy: LoomDirectConnectionPolicy

    /// Optional local device identifier used to filter self from discovery results.
    public var localDeviceID: UUID?

    /// Callback invoked whenever discovered peers change.
    public var onPeersChanged: (([LoomPeer]) -> Void)?

    /// Callback invoked when the local network access denial state changes.
    public var onLocalNetworkAccessDeniedChanged: ((Bool) -> Void)?

    /// Whether Bonjour browsing is currently marked as denied by local network privacy.
    public private(set) var localNetworkAccessDenied = false

    /// Additional peer-change observers keyed by registration token.
    private var peersChangedObservers: [UUID: ([LoomPeer]) -> Void] = [:]

    private var browser: NWBrowser?
    private var txtRecordMonitor: BonjourTXTRecordMonitor?
    private var stoppingTXTRecordMonitors: [BonjourTXTRecordMonitor] = []
    private var browserCanRefreshInPlace = false
    private let browserQueue = DispatchQueue(label: "com.mirage.loom.discovery.browser", qos: .utility)
    private let serviceType: String
    private var browseResultsByEndpoint: [NWEndpoint: NWBrowser.Result] = [:]
    private var txtRecordsByService: [BonjourServiceIdentity: [String: String]] = [:]
    private var resolvedAddressesByService: [BonjourServiceIdentity: [NWEndpoint.Host]] = [:]
    private var peerCandidatesByDeviceID: [UUID: [NWEndpoint: LoomHostDiscoveryCandidate]] = [:]
    private var peerIDByEndpoint: [NWEndpoint: UUID] = [:]
    private var peersByID: [LoomPeerID: LoomPeer] = [:]
    private var lastPublishedPeerSnapshots: [PublishedPeerSnapshot] = []

    public init(
        serviceType: String = Loom.serviceType,
        enableBonjour: Bool = true,
        enablePeerToPeer: Bool = true,
        directConnectionPolicy: LoomDirectConnectionPolicy = .default,
        localDeviceID: UUID? = nil
    ) {
        self.serviceType = serviceType
        self.enableBonjour = enableBonjour
        self.enablePeerToPeer = enablePeerToPeer
        self.directConnectionPolicy = directConnectionPolicy
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
                self?.handleBrowseResults(changes: changes)
            }
        }

        browser?.start(queue: browserQueue)
        isSearching = true
    }

    nonisolated package static func makeBrowserParameters(enablePeerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = enablePeerToPeer
        parameters.allowUltraConstrainedPaths = enablePeerToPeer
        return parameters
    }

    /// Stop discovery.
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        browserCanRefreshInPlace = false
        stopTXTRecordMonitor()
        isSearching = false
        isBrowserReady = false
        browseResultsByEndpoint.removeAll()
        txtRecordsByService.removeAll()
        resolvedAddressesByService.removeAll()
        peerCandidatesByDeviceID.removeAll()
        peerIDByEndpoint.removeAll()
        peersByID.removeAll()
        publishDiscoveredPeers([])
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .setup,
             .waiting:
            browserCanRefreshInPlace = true
        case .ready:
            isSearching = true
            browserCanRefreshInPlace = true
            isBrowserReady = true
            setLocalNetworkAccessDenied(false)
        case .cancelled:
            isSearching = false
            browserCanRefreshInPlace = false
            isBrowserReady = false
        case let .failed(error):
            isSearching = false
            browserCanRefreshInPlace = false
            isBrowserReady = false
            setLocalNetworkAccessDenied(Self.isLocalNetworkAccessDenied(error))
        default:
            break
        }
    }

    private func setLocalNetworkAccessDenied(_ value: Bool) {
        guard localNetworkAccessDenied != value else { return }
        localNetworkAccessDenied = value
        onLocalNetworkAccessDeniedChanged?(value)
    }

    private static func isLocalNetworkAccessDenied(_ error: Error) -> Bool {
        if let nwError = error as? NWError,
           case let .dns(code) = nwError {
            return code == -65_555
        }

        let nsError = error as NSError
        return nsError.domain == NetService.errorDomain && nsError.code == -65_555
    }

    private func stopTXTRecordMonitor() {
        guard let monitor = txtRecordMonitor else { return }
        txtRecordMonitor = nil
        stoppingTXTRecordMonitors.append(monitor)
        monitor.stop { [weak self, weak monitor] in
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor else { return }
                self.stoppingTXTRecordMonitors.removeAll { $0 === monitor }
            }
        }
    }

    private func handleBrowseResults(changes: Set<NWBrowser.Result.Change>) {
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
            resolvedAddresses: resolvedAddresses,
            discoveredInterfaces: result.interfaces.map(LoomDiscoveredInterface.init)
        )
    }

    private func upsertBonjourPeer(
        peerName: String,
        endpoint: NWEndpoint,
        txtRecord: [String: String],
        resolvedAddresses: [NWEndpoint.Host] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
    ) {
        let decodedAdvertisement = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        if !txtRecord.isEmpty {
            LoomLogger.discovery(
                "Peer metadata \(peerName): did=\(decodedAdvertisement.deviceID?.uuidString ?? "nil") type=\(decodedAdvertisement.deviceType?.rawValue ?? "unknown") keys=\(txtRecord.keys.sorted())"
            )
        }

        guard let peerID = decodedAdvertisement.deviceID else {
            removePeer(for: endpoint)
            return
        }

        guard peerID != localDeviceID else {
            removePeer(for: endpoint)
            return
        }

        let advertisement = mergeTransportHints(
            from: decodedAdvertisement,
            endpoint: endpoint,
            peerID: peerID
        )
        let normalizedAdvertisement = LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
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
            resolvedAddresses: resolvedAddresses,
            discoveredInterfaces: discoveredInterfaces
        )

        storeCandidate(candidate, for: endpoint, peerID: peerID)
    }

    private func mergeTransportHints(
        from advertisement: LoomPeerAdvertisement,
        endpoint: NWEndpoint,
        peerID: UUID
    ) -> LoomPeerAdvertisement {
        guard let existingAdvertisement = peerCandidatesByDeviceID[peerID]?[endpoint]?.advertisement else {
            return advertisement
        }

        var transportsByKind = existingAdvertisement.directTransports.reduce(
            into: [LoomTransportKind: LoomDirectTransportAdvertisement]()
        ) { result, transport in
            result[transport.transportKind] = transport
        }
        for transport in advertisement.directTransports {
            transportsByKind[transport.transportKind] = transport
        }

        let mergedTransports = LoomTransportKind.allCases.compactMap { transportsByKind[$0] }
        guard mergedTransports != advertisement.directTransports else {
            return advertisement
        }

        return LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
            identityKeyID: advertisement.identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            hostName: advertisement.hostName,
            directTransports: mergedTransports,
            metadata: advertisement.metadata
        )
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
        let updatedPeers = Array(peersByID.values).sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        publishDiscoveredPeers(updatedPeers)
    }

    /// Force a discovery refresh.
    public func refresh(forceRestart: Bool = false, reason: String? = nil) {
        guard enableBonjour else {
            stopDiscovery()
            return
        }

        if forceRestart {
            if let reason, !reason.isEmpty {
                LoomLogger.discovery("Restarting discovery: \(reason)")
            } else {
                LoomLogger.discovery("Restarting discovery")
            }
            stopDiscovery()
            startDiscovery()
            return
        }

        guard browser == nil || !browserCanRefreshInPlace else {
            LoomLogger.discovery("Discovery refresh skipped; Bonjour browser is already active")
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
            advertisement: peer.advertisement,
            resolvedAddresses: peer.resolvedAddresses,
            discoveredInterfaces: peer.discoveredInterfaces
        )
        storeCandidate(candidate, for: peer.endpoint, peerID: peer.deviceID)
    }

    package func upsertBonjourPeerForTesting(
        peerName: String,
        endpoint: NWEndpoint,
        txtRecord: [String: String],
        resolvedAddresses: [NWEndpoint.Host] = [],
        discoveredInterfaces: [LoomDiscoveredInterface] = []
    ) {
        upsertBonjourPeer(
            peerName: peerName,
            endpoint: endpoint,
            txtRecord: txtRecord,
            resolvedAddresses: resolvedAddresses,
            discoveredInterfaces: discoveredInterfaces
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
        let discoveredInterfaces = mergedDiscoveredInterfaces(from: candidates.values)
        let resolvedAddresses = mergedResolvedAddresses(
            from: candidates.values,
            preferredCandidate: preferredCandidate
        )

        removeProjectedPeers(forDeviceID: peerID)
        let projections = LoomHostCatalogCodec.projections(
            peerName: preferredCandidate.name,
            advertisement: preferredCandidate.advertisement,
            fallbackDeviceID: peerID
        )
        for projection in projections {
            peersByID[projection.peerID] = LoomPeer(
                id: projection.peerID,
                name: projection.displayName,
                deviceType: preferredCandidate.deviceType,
                endpoint: preferredCandidate.endpoint,
                advertisement: projection.advertisement,
                resolvedAddresses: resolvedAddresses,
                discoveredInterfaces: discoveredInterfaces
            )
        }
        updatePeersList()
    }

    private func mergedResolvedAddresses(
        from candidates: Dictionary<NWEndpoint, LoomHostDiscoveryCandidate>.Values,
        preferredCandidate: LoomHostDiscoveryCandidate
    ) -> [NWEndpoint.Host] {
        var resolvedAddresses: [NWEndpoint.Host] = []
        var seenKeys: Set<String> = []

        func append(_ hosts: [NWEndpoint.Host]) {
            for host in hosts {
                let key = host.debugDescription.lowercased()
                guard seenKeys.insert(key).inserted else {
                    continue
                }
                resolvedAddresses.append(host)
            }
        }

        append(preferredCandidate.resolvedAddresses)

        let remainingCandidates = candidates
            .filter { $0.endpoint.debugDescription != preferredCandidate.endpoint.debugDescription }
            .sorted { lhs, rhs in
                isPreferredPeer(lhs, rhs)
            }
        for candidate in remainingCandidates {
            append(candidate.resolvedAddresses)
        }

        return resolvedAddresses
    }

    private func mergedDiscoveredInterfaces(
        from candidates: Dictionary<NWEndpoint, LoomHostDiscoveryCandidate>.Values
    ) -> [LoomDiscoveredInterface] {
        var interfacesByKey: [String: LoomDiscoveredInterface] = [:]
        for candidate in candidates {
            for discoveredInterface in candidate.discoveredInterfaces {
                let key: String
                if discoveredInterface.index > 0 {
                    key = "index:\(discoveredInterface.index)"
                } else {
                    key = "name:\(discoveredInterface.name.lowercased())"
                }
                if interfacesByKey[key]?.networkInterface == nil {
                    interfacesByKey[key] = discoveredInterface
                }
            }
        }
        return interfacesByKey.values.sorted { lhs, rhs in
            let leftPriority = lhs.proximityPriority ?? Int.max
            let rightPriority = rhs.proximityPriority ?? Int.max
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            if lhs.isPeerToPeer != rhs.isPeerToPeer {
                return lhs.isPeerToPeer
            }
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.name < rhs.name
        }
    }

    private func isPreferredPeer(_ lhs: LoomHostDiscoveryCandidate, _ rhs: LoomHostDiscoveryCandidate) -> Bool {
        let leftTransport = lhs.advertisement.directTransports.min(by: transportIsPreferred(_:_:))
        let rightTransport = rhs.advertisement.directTransports.min(by: transportIsPreferred(_:_:))
        switch (leftTransport, rightTransport) {
        case let (left?, right?):
            if transportIsPreferred(left, right) {
                return true
            }
            if transportIsPreferred(right, left) {
                return false
            }
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            break
        }
        return lhs.endpoint.debugDescription < rhs.endpoint.debugDescription
    }

    private func removeProjectedPeers(forDeviceID peerID: UUID) {
        peersByID = peersByID.filter { $0.key.deviceID != peerID }
    }

    private func transportIsPreferred(
        _ lhs: LoomDirectTransportAdvertisement,
        _ rhs: LoomDirectTransportAdvertisement
    ) -> Bool {
        let leftPathRank = pathRank(lhs.pathKind)
        let rightPathRank = pathRank(rhs.pathKind)
        if leftPathRank != rightPathRank {
            return leftPathRank < rightPathRank
        }
        let leftTransportRank = transportRank(lhs.transportKind)
        let rightTransportRank = transportRank(rhs.transportKind)
        if leftTransportRank != rightTransportRank {
            return leftTransportRank < rightTransportRank
        }
        return lhs.port < rhs.port
    }

    private func pathRank(_ pathKind: LoomDirectPathKind?) -> Int {
        directConnectionPolicy.preferredLocalPathOrder.firstIndex(of: pathKind ?? .other) ?? Int.max
    }

    private func transportRank(_ transportKind: LoomTransportKind) -> Int {
        directConnectionPolicy.preferredTransportOrder.firstIndex(of: transportKind) ?? Int.max
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

    private func publishDiscoveredPeers(_ peers: [LoomPeer]) {
        let snapshots = peers.map(PublishedPeerSnapshot.init)
        guard snapshots != lastPublishedPeerSnapshots else { return }

        discoveredPeers = peers
        lastPublishedPeerSnapshots = snapshots
        onPeersChanged?(peers)
        for observer in peersChangedObservers.values {
            observer(peers)
        }
    }
}

private struct PublishedPeerSnapshot: Equatable {
    let id: LoomPeerID
    let name: String
    let deviceType: DeviceType
    let endpoint: NWEndpoint
    let advertisement: LoomPeerAdvertisement
    let resolvedAddresses: [NWEndpoint.Host]
    let discoveredInterfaces: [LoomDiscoveredInterface]

    init(_ peer: LoomPeer) {
        id = peer.id
        name = peer.name
        deviceType = peer.deviceType
        endpoint = peer.endpoint
        advertisement = peer.advertisement
        resolvedAddresses = peer.resolvedAddresses
        discoveredInterfaces = peer.discoveredInterfaces
    }
}

private struct LoomHostDiscoveryCandidate {
    let name: String
    let deviceType: DeviceType
    let endpoint: NWEndpoint
    let advertisement: LoomPeerAdvertisement
    let resolvedAddresses: [NWEndpoint.Host]
    let discoveredInterfaces: [LoomDiscoveredInterface]
}
