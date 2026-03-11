//
//  LoomOverlayProbeServerTests.swift
//  Loom
//
//  Created by Codex on 3/11/26.
//

@testable import Loom
import Darwin
import Foundation
import Testing

@Suite("Loom Overlay Probe Server", .serialized)
struct LoomOverlayProbeServerTests {
    @MainActor
    @Test("Probe responses mirror the authenticated advertisement after listener ports are assigned")
    func probeResponseMirrorsAdvertisedPorts() async throws {
        let serviceName = "Overlay Probe Host"
        let probePort = try await reserveRandomPort()
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.overlay-probe.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                serviceType: uniqueTestServiceType(prefix: "lop"),
                overlayProbePort: probePort,
                enablePeerToPeer: false,
                enabledDirectTransports: [.tcp]
            ),
            identityManager: identityManager
        )
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!

        do {
            let ports = try await node.startAuthenticatedAdvertising(
                serviceName: serviceName,
                helloProvider: {
                    LoomSessionHelloRequest(
                        deviceID: deviceID,
                        deviceName: serviceName,
                        deviceType: .mac,
                        advertisement: LoomPeerAdvertisement(
                            deviceID: deviceID,
                            deviceType: .mac
                        )
                    )
                },
                onSession: { _ in }
            )
            let response = try await LoomOverlayProbeClient.probe(
                seed: LoomOverlaySeed(host: "127.0.0.1", probePort: probePort),
                defaultPort: Loom.defaultOverlayProbePort,
                timeout: .seconds(2)
            )

            #expect(response.name == serviceName)
            #expect(response.advertisement.deviceID == deviceID)
            #expect(response.advertisement.directTransports == [
                LoomDirectTransportAdvertisement(
                    transportKind: .tcp,
                    port: try #require(ports[.tcp])
                ),
            ])
        } catch {
            await node.stopAdvertising()
            throw error
        }

        await node.stopAdvertising()
    }

    @MainActor
    @Test("Failed overlay probe startup tears down the TCP advertiser")
    func failedOverlayProbeStartupTearsDownAdvertising() async throws {
        let occupiedServer = LoomOverlayProbeServer(port: try reserveAvailableTCPPort()) {
            LoomOverlayProbeResponse(
                name: "Occupied Probe",
                deviceType: .mac,
                advertisement: LoomPeerAdvertisement(deviceType: .mac)
            )
        }
        let occupiedProbePort = try await occupiedServer.start()
        let controlPort = try reserveAvailableTCPPort(excluding: [occupiedProbePort])
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                serviceType: uniqueTestServiceType(prefix: "lop"),
                controlPort: controlPort,
                overlayProbePort: occupiedProbePort,
                enablePeerToPeer: false,
                enabledDirectTransports: [.tcp]
            ),
            identityManager: LoomIdentityManager(
                service: "com.ethanlipnik.loom.tests.overlay-probe-failure.\(UUID().uuidString)",
                account: "p256-signing",
                synchronizable: false
            )
        )

        do {
            do {
                _ = try await node.startAuthenticatedAdvertising(
                    serviceName: "Overlay Failure Host",
                    helloProvider: {
                        LoomSessionHelloRequest(
                            deviceID: deviceID,
                            deviceName: "Overlay Failure Host",
                            deviceType: .mac,
                            advertisement: LoomPeerAdvertisement(
                                deviceID: deviceID,
                                deviceType: .mac
                            )
                        )
                    },
                    onSession: { _ in }
                )
                Issue.record("Expected occupied overlay probe port to make advertising fail.")
            } catch {
                #expect(await waitUntilTCPPortCloses(controlPort))
            }
        }

        await node.stopAdvertising()
        await occupiedServer.stop()
    }
}

private func reserveRandomPort() async throws -> UInt16 {
    try await withThrowingTaskGroup(of: UInt16.self) { group in
        group.addTask {
            for _ in 0..<32 {
                let port = UInt16.random(in: 20000...60000)
                if port != Loom.defaultOverlayProbePort {
                    return port
                }
            }
            throw LoomError.protocolError("Unable to pick a test overlay probe port.")
        }

        let port = try await group.next()!
        group.cancelAll()
        return port
    }
}

private func uniqueTestServiceType(prefix: String) -> String {
    "_\(prefix)\(UUID().uuidString.prefix(6).lowercased())._tcp"
}

private func reserveAvailableTCPPort(
    excluding excludedPorts: Set<UInt16> = []
) throws -> UInt16 {
    for _ in 0..<32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            continue
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                bind(descriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            continue
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                getsockname(descriptor, reboundPointer, &length)
            }
        }
        guard nameResult == 0 else {
            continue
        }

        let port = UInt16(bigEndian: boundAddress.sin_port)
        if port > 0,
           excludedPorts.contains(port) == false {
            return port
        }
    }

    throw LoomError.protocolError("Unable to reserve an available TCP port.")
}

private func canEstablishTCPConnection(to port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        return false
    }
    defer {
        close(descriptor)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
            connect(descriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

private func waitUntilTCPPortCloses(
    _ port: UInt16,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if canEstablishTCPConnection(to: port) == false {
            return true
        }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}
