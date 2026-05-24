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
}
