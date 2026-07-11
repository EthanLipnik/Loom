//
//  BonjourBrowserPortable.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking
import LoomPlatformAdapters
import Observation

/// Discovers Loom peers through a backend-independent DNS-SD browser.
@Observable
@MainActor
public final class LoomPortableDiscovery {
    public private(set) var discoveredPeers: [LoomPeer] = []
    public private(set) var isSearching = false
    public private(set) var isBrowserReady = false
    public var enablePeerToPeer: Bool
    public var enableBonjour: Bool
    public var directConnectionPolicy: LoomDirectConnectionPolicy
    public var localDeviceID: UUID?
    public var onPeersChanged: (([LoomPeer]) -> Void)?
    public var onLocalNetworkAccessDeniedChanged: ((Bool) -> Void)?
    public private(set) var localNetworkAccessDenied = false

    private let serviceType: String
    private var browser: (any LoomDNSServiceBrowser)?
    private var browseTask: Task<Void, Never>?
    private var generation = UUID()
    private var instances: [LoomDNSServiceIdentity: LoomDNSServiceInstance] = [:]
    private var peersChangedObservers: [UUID: ([LoomPeer]) -> Void] = [:]
    private var lastPublishedPeerSnapshots: [PortablePublishedPeerSnapshot] = []

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

    public func startDiscovery() {
        guard enableBonjour else {
            stopDiscovery()
            return
        }
        guard !isSearching else { return }
        do {
            let browser = try LoomPlatformDNSServiceBackend().makeBrowser(
                configuration: LoomDNSServiceConfiguration(
                    serviceType: serviceType,
                    domain: "local",
                    includePeerToPeer: enablePeerToPeer
                )
            )
            let currentGeneration = UUID()
            generation = currentGeneration
            self.browser = browser
            isSearching = true
            browseTask = Task { [weak self, browser] in
                do {
                    let events = await browser.makeEventStream()
                    try await browser.start()
                    for await event in events {
                        guard !Task.isCancelled else { break }
                        self?.handle(event, generation: currentGeneration)
                    }
                } catch {
                    self?.handleFailure(error, generation: currentGeneration)
                }
            }
        } catch {
            handleFailure(error, generation: generation)
        }
    }

    public func stopDiscovery() {
        generation = UUID()
        browseTask?.cancel()
        browseTask = nil
        let browser = self.browser
        self.browser = nil
        Task {
            await browser?.cancel()
        }
        isSearching = false
        isBrowserReady = false
        instances.removeAll()
        publishDiscoveredPeers([])
    }

    public func refresh(forceRestart: Bool = false, reason: String? = nil) {
        _ = forceRestart
        _ = reason
        stopDiscovery()
        if enableBonjour {
            startDiscovery()
        }
    }

    @discardableResult
    public func addPeersChangedObserver(_ observer: @escaping ([LoomPeer]) -> Void) -> UUID {
        let token = UUID()
        peersChangedObservers[token] = observer
        return token
    }

    public func removePeersChangedObserver(_ token: UUID) {
        peersChangedObservers.removeValue(forKey: token)
    }

    private func handle(_ event: LoomDNSServiceBrowserEvent, generation eventGeneration: UUID) {
        guard generation == eventGeneration else { return }
        switch event {
        case .ready:
            isSearching = true
            isBrowserReady = true
        case let .added(instance), let .changed(instance):
            instances[instance.identity] = instance
            rebuildPeers()
        case let .removed(identity):
            instances.removeValue(forKey: identity)
            rebuildPeers()
        case let .failed(error):
            handleFailure(error, generation: eventGeneration)
        case .cancelled:
            isSearching = false
            isBrowserReady = false
        }
    }

    private func handleFailure(_ error: any Error, generation eventGeneration: UUID) {
        guard generation == eventGeneration else { return }
        LoomLogger.error(.discovery, error: error, message: "DNS-SD discovery failed")
        isSearching = false
        isBrowserReady = false
    }

    private func rebuildPeers() {
        var candidatesByDeviceID: [UUID: [PortableDiscoveryCandidate]] = [:]
        for instance in instances.values {
            let advertisement = LoomPeerAdvertisement.from(
                txtRecord: instance.txtRecord.stringDictionary
            )
            guard let deviceID = advertisement.deviceID,
                  deviceID != localDeviceID else {
                continue
            }
            candidatesByDeviceID[deviceID, default: []].append(
                PortableDiscoveryCandidate(instance: instance, advertisement: advertisement)
            )
        }

        var peers: [LoomPeer] = []
        for (deviceID, candidates) in candidatesByDeviceID {
            guard let preferred = candidates.min(by: candidateIsPreferred(_:_:)) else { continue }
            var addresses: [LoomNetworkHost] = []
            var seenAddresses: Set<LoomNetworkHost> = []
            for candidate in [preferred] + candidates.filter({ $0.instance.identity != preferred.instance.identity }) {
                for address in candidate.instance.addresses where seenAddresses.insert(address).inserted {
                    addresses.append(address)
                }
            }
            let interfaceIndices = Set(candidates.compactMap(\.instance.identity.interfaceIndex))
            let interfaces = interfaceIndices.sorted().map {
                LoomDiscoveredInterface(
                    name: "if\($0)",
                    backendType: .other,
                    index: Int($0)
                )
            }
            let resolvedServiceAddresses = addresses.map { address in
                let scope = Self.scopeIdentifier(in: address)
                return LoomResolvedServiceAddress(
                    backendHost: address,
                    interfaceName: scope,
                    interfaceKind: nil
                )
            }
            let endpoint: LoomNetworkEndpoint
            if let address = addresses.first {
                endpoint = .hostPort(host: address, port: preferred.instance.port)
            } else if let hostName = preferred.instance.hostName {
                endpoint = .hostPort(host: LoomNetworkHost(hostName), port: preferred.instance.port)
            } else {
                endpoint = .service(
                    name: preferred.instance.identity.name,
                    type: preferred.instance.identity.type,
                    domain: preferred.instance.identity.domain,
                    interfaceName: preferred.instance.identity.interfaceIndex.map(String.init)
                )
            }
            let projections = LoomHostCatalogCodec.projections(
                peerName: preferred.instance.identity.name,
                advertisement: preferred.advertisement,
                fallbackDeviceID: deviceID
            )
            for projection in projections {
                peers.append(
                    LoomPeer(
                        id: projection.peerID,
                        name: projection.displayName,
                        deviceType: preferred.advertisement.deviceType ?? .unknown,
                        backendEndpoint: endpoint,
                        advertisement: projection.advertisement,
                        backendResolvedAddresses: addresses,
                        resolvedServiceAddresses: resolvedServiceAddresses,
                        discoveredInterfaces: interfaces
                    )
                )
            }
        }
        publishDiscoveredPeers(peers.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return String(describing: lhs.id) < String(describing: rhs.id)
        })
    }

    private func candidateIsPreferred(
        _ lhs: PortableDiscoveryCandidate,
        _ rhs: PortableDiscoveryCandidate
    ) -> Bool {
        let leftTransport = lhs.advertisement.directTransports.min(by: transportIsPreferred(_:_:))
        let rightTransport = rhs.advertisement.directTransports.min(by: transportIsPreferred(_:_:))
        switch (leftTransport, rightTransport) {
        case let (left?, right?):
            if transportIsPreferred(left, right) { return true }
            if transportIsPreferred(right, left) { return false }
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            break
        }
        return lhs.instance.identity.fullyQualifiedName < rhs.instance.identity.fullyQualifiedName
    }

    private func transportIsPreferred(
        _ lhs: LoomDirectTransportAdvertisement,
        _ rhs: LoomDirectTransportAdvertisement
    ) -> Bool {
        let leftPath = directConnectionPolicy.preferredLocalPathOrder.firstIndex(of: lhs.pathKind ?? .other) ?? Int.max
        let rightPath = directConnectionPolicy.preferredLocalPathOrder.firstIndex(of: rhs.pathKind ?? .other) ?? Int.max
        if leftPath != rightPath { return leftPath < rightPath }
        let leftTransport = directConnectionPolicy.preferredTransportOrder.firstIndex(of: lhs.transportKind) ?? Int.max
        let rightTransport = directConnectionPolicy.preferredTransportOrder.firstIndex(of: rhs.transportKind) ?? Int.max
        if leftTransport != rightTransport { return leftTransport < rightTransport }
        return lhs.port < rhs.port
    }

    private func publishDiscoveredPeers(_ peers: [LoomPeer]) {
        let snapshots = peers.map(PortablePublishedPeerSnapshot.init)
        guard snapshots != lastPublishedPeerSnapshots else { return }
        lastPublishedPeerSnapshots = snapshots
        discoveredPeers = peers
        onPeersChanged?(peers)
        for observer in peersChangedObservers.values {
            observer(peers)
        }
    }

    private static func scopeIdentifier(in host: LoomNetworkHost) -> String? {
        guard let separator = host.rawValue.lastIndex(of: "%") else { return nil }
        let value = host.rawValue[host.rawValue.index(after: separator)...]
        return value.isEmpty ? nil : String(value)
    }
}

private struct PortableDiscoveryCandidate {
    let instance: LoomDNSServiceInstance
    let advertisement: LoomPeerAdvertisement
}

private struct PortablePublishedPeerSnapshot: Equatable {
    let id: LoomPeerID
    let name: String
    let deviceType: DeviceType
    let endpoint: LoomNetworkEndpoint
    let advertisement: LoomPeerAdvertisement
    let resolvedAddresses: [LoomNetworkHost]
    let resolvedServiceAddresses: [LoomResolvedServiceAddress]
    let discoveredInterfaces: [LoomDiscoveredInterface]

    init(_ peer: LoomPeer) {
        id = peer.id
        name = peer.name
        deviceType = peer.deviceType
        endpoint = peer.backendEndpoint
        advertisement = peer.advertisement
        resolvedAddresses = peer.backendResolvedAddresses
        resolvedServiceAddresses = peer.resolvedServiceAddresses
        discoveredInterfaces = peer.discoveredInterfaces
    }
}

#if !canImport(Network)
public typealias LoomDiscovery = LoomPortableDiscovery
#endif
