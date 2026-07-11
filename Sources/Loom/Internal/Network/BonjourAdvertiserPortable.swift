//
//  BonjourAdvertiserPortable.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking
import LoomPlatformAdapters

/// DNS-SD advertisement paired with a backend-independent TCP listener.
actor LoomPortableBonjourAdvertiser {
    typealias FailureHandler = @Sendable (String) -> Void

    private let serviceName: String
    private let serviceType: String
    private let networkBackend: any LoomNetworkBackend
    private let onFailureAfterReady: FailureHandler?
    private var advertisement: LoomPeerAdvertisement
    private var listener: (any LoomNetworkListener)?
    private var dnsAdvertiser: (any LoomDNSServiceAdvertiser)?
    private var acceptTask: Task<Void, Never>?
    private var generation = UUID()

    private(set) var port: UInt16 = 0

    init(
        serviceName: String,
        advertisement: LoomPeerAdvertisement,
        serviceType: String,
        enablePeerToPeer: Bool,
        networkBackend: any LoomNetworkBackend,
        onFailureAfterReady: FailureHandler? = nil
    ) {
        self.serviceName = serviceName
        self.advertisement = advertisement
        self.serviceType = serviceType
        self.networkBackend = networkBackend
        self.onFailureAfterReady = onFailureAfterReady
        _ = enablePeerToPeer
    }

    func start(
        port requestedPort: UInt16 = 0,
        onConnection: @escaping LoomDirectConnectionHandler
    ) async throws -> UInt16 {
        let currentGeneration = UUID()
        generation = currentGeneration
        let listener = try networkBackend.makeListener(
            using: .tcp,
            configuration: LoomNetworkListenerConfiguration()
        )
        let stream = await listener.makeConnectionStream()
        let acceptTask = Task { [listener] in
            for await connection in stream {
                guard !Task.isCancelled else {
                    await connection.cancel()
                    break
                }
                await onConnection(connection)
            }
            if Task.isCancelled {
                await listener.cancel()
            }
        }
        self.listener = listener
        self.acceptTask = acceptTask

        do {
            let actualPort = try await listener.start(port: requestedPort)
            guard generation == currentGeneration else {
                throw CancellationError()
            }
            let txtRecord = try LoomTXTRecord(advertisement.toTXTRecord())
            let dnsAdvertiser = try LoomPlatformDNSServiceBackend().makeAdvertiser(
                identity: LoomDNSServiceIdentity(
                    name: serviceName,
                    type: serviceType,
                    domain: "local"
                ),
                hostName: nil,
                port: actualPort,
                txtRecord: txtRecord
            )
            try await dnsAdvertiser.start()
            guard generation == currentGeneration else {
                await dnsAdvertiser.cancel()
                throw CancellationError()
            }
            self.dnsAdvertiser = dnsAdvertiser
            port = actualPort
            return actualPort
        } catch {
            generation = UUID()
            acceptTask.cancel()
            self.acceptTask = nil
            self.listener = nil
            await listener.cancel()
            throw error
        }
    }

    func updateAdvertisement(_ advertisement: LoomPeerAdvertisement) async {
        self.advertisement = advertisement
        guard let dnsAdvertiser else { return }
        do {
            try await dnsAdvertiser.updateTXTRecord(
                LoomTXTRecord(advertisement.toTXTRecord())
            )
        } catch {
            onFailureAfterReady?(error.localizedDescription)
        }
    }

    func stop() async {
        generation = UUID()
        let dnsAdvertiser = self.dnsAdvertiser
        self.dnsAdvertiser = nil
        let listener = self.listener
        self.listener = nil
        acceptTask?.cancel()
        acceptTask = nil
        port = 0
        await dnsAdvertiser?.cancel()
        await listener?.cancel()
    }
}

#if !canImport(Network)
typealias BonjourAdvertiser = LoomPortableBonjourAdvertiser
#endif
