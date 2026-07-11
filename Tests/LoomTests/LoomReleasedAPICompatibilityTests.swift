//
//  LoomReleasedAPICompatibilityTests.swift
//  LoomTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Network
import Testing
@testable import Loom

@Suite("Released Loom API Compatibility")
struct LoomReleasedAPICompatibilityTests {
    @MainActor
    @Test("Loom 2.1 public initializers and transport spellings remain source compatible")
    func releasedInitializersRemainSourceCompatible() {
        let identity = LoomIdentityManager(
            service: "com.loom.compatibility",
            account: "p256-signing",
            synchronizable: false,
            fallbackToNonSynchronizableStorage: false,
            storage: .memory
        )
        let configuration = LoomNetworkConfiguration(
            serviceType: "_loom-compatibility._tcp",
            controlPort: 38_447,
            dataPort: 38_448,
            udpPort: 38_449,
            maxPacketSize: 1_200,
            enableBonjour: false,
            enablePeerToPeer: false,
            requireEncryptedMediaOnLocalNetwork: true,
            enabledDirectTransports: [.tcp, .udp],
            directDatagramServiceClass: .interactiveVideo
        )
        let node = LoomNode(
            configuration: configuration,
            identityManager: identity,
            trustProvider: nil
        )

        #expect(node.configuration.enabledDirectTransports == Set([.tcp, .udp]))
        #expect(LoomTransportKind.allCases == [.tcp, .quic, .udp])
        #expect(releasedStorageName(.keychain) == "keychain")
        #expect(releasedStorageName(.memory) == "memory")
    }

    private func releasedStorageName(_ storage: LoomIdentityStorage) -> String {
        switch storage {
        case .keychain:
            "keychain"
        case .memory:
            "memory"
        }
    }
}
