# Getting Started

Build a `LoomNode`, advertise your local device, discover peers, then wrap an `NWConnection` in a `LoomSession` once you decide to connect.

## Create A Node

```swift
import Loom

let node = LoomNode(
    configuration: LoomNetworkConfiguration(
        serviceType: "_myapp._tcp",
        enablePeerToPeer: true
    ),
    identityManager: LoomIdentityManager.shared
)
```

`LoomNode` is intentionally small. It is the composition root for discovery, identity, and trust dependencies.

## Advertise

```swift
import Foundation

let identity = try LoomIdentityManager.shared.currentIdentity()

let advertisement = LoomPeerAdvertisement(
    deviceID: UUID(),
    identityKeyID: identity.keyID,
    deviceType: .mac,
    metadata: [
        "myapp.role": "builder",
        "myapp.version": "1",
    ]
)

let port = try await node.startAdvertising(
    serviceName: "My Mac",
    advertisement: advertisement
) { session in
    session.start(queue: .main)
}

print("Advertising on port \\(port)")
```

## Discover

```swift
let discovery = node.makeDiscovery()

discovery.onPeersChanged = { peers in
    for peer in peers {
        print("Found \\(peer.name) at \\(peer.endpoint)")
    }
}

discovery.startDiscovery()
```

## Connect

```swift
import Network

let connection = NWConnection(to: peer.endpoint, using: .tcp)
let session = node.makeSession(connection: connection)

session.setStateUpdateHandler { state in
    print("Session state:", state)
}

session.start(queue: .main)
```

## Extend Above Loom

Loom should stop at the networking boundary. Keep product-specific protocols, message schemas, CloudKit naming, and UI semantics in the package or app that depends on Loom.
