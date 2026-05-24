import Foundation
import Loom

@MainActor
final class MyHostService {
    enum State: Equatable {
        case idle
        case advertising(ports: [LoomTransportKind: UInt16])
        case failed(String)
    }

    private let deviceID: UUID
    private let serviceName: String
    private let node: LoomNode

    private(set) var state: State = .idle

    init(
        serviceName: String,
        deviceID: UUID = loadOrCreateStableDeviceID(),
        trustProvider: (any LoomTrustProvider)? = nil
    ) {
        self.deviceID = deviceID
        self.serviceName = serviceName
        node = LoomNode(
            configuration: LoomNetworkConfiguration(
                serviceType: "_myapp._tcp",
                enablePeerToPeer: true
            ),
            identityManager: LoomIdentityManager.shared,
            trustProvider: trustProvider
        )
    }

    private func makeAdvertisement() throws -> LoomPeerAdvertisement {
        let identity = try LoomIdentityManager.shared.currentIdentity()

        return LoomPeerAdvertisement(
            deviceID: deviceID,
            identityKeyID: identity.keyID,
            deviceType: .mac,
            modelIdentifier: currentHardwareModelIdentifier(),
            metadata: [
                "myapp.protocol": "1",
                "myapp.role": "host",
                "myapp.max-streams": "4",
            ]
        )
    }

    func refreshAdvertisement() async throws {
        let advertisement = try makeAdvertisement()
        await node.updateAdvertisement(advertisement)
    }
}
