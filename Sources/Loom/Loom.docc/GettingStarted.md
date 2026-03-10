# Getting Started

Use this guide to get a real Loom integration off the ground. The short version is:

1. start with `LoomKit` if your app is SwiftUI-first and you want a container/context/query model
2. drop down to an app-owned `LoomNode` when you need full control of discovery and transport wiring
3. keep your protocol, approval UX, and product policy above Loom

That is the same boundary `MirageKit` uses. Its host and client services both own a ``LoomNode``, but the handshake schema, stream model, CloudKit policy, and UI all live above Loom.

## Start with LoomKit for SwiftUI apps

If you want something modeled more like SwiftData than like a pile of networking services, use the `LoomKit` product first.

`LoomKit` gives you:

- one shared `LoomContainer`
- a main-actor `LoomContext` in the environment
- live `@LoomQuery` peer, connection, and transfer snapshots
- actor-backed `LoomConnectionHandle` values for messages, files, and custom streams

```swift
import LoomKit
import SwiftUI

@main
struct StudioLinkApp: App {
    let loomContainer = try! LoomContainer(
        for: .init(
            serviceType: "_studiolink._tcp",
            serviceName: "Studio Mac",
            deviceIDSuiteName: "group.com.example.studiolink"
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .loomContainer(loomContainer)
    }
}
```

```swift
import LoomKit
import SwiftUI

struct ContentView: View {
    @Environment(\.loomContext) private var loomContext
    @LoomQuery(.peers(sort: .name)) private var peers: [LoomPeerSnapshot]

    var body: some View {
        List(peers) { peer in
            Button(peer.name) {
                Task {
                    let connection = try await loomContext.connect(peer)
                    try await connection.send("hello")
                }
            }
        }
    }
}
```

That is the recommended entry point for most SwiftUI apps. Once a connection exists, you still own protocol semantics and product behavior above LoomKit.

## Build from Loom primitives when you need total control

## Create an app-owned node

Start by choosing product defaults that belong to your app, not to Loom:

- a Bonjour service type
- whether peer-to-peer browsing is allowed
- how you persist a stable device ID
- which trust provider, if any, should be injected

```swift
import Loom

let configuration = LoomNetworkConfiguration(
    serviceType: "_myapp._tcp",
    enablePeerToPeer: true
)

let node = LoomNode(
    configuration: configuration,
    identityManager: LoomIdentityManager.shared
)
```

`LoomNode` is intentionally small. Treat it as the networking composition root for one runtime surface in your app.

`MirageKit` follows this pattern directly: its host service and client service each own a node, override Loom's default service type, and keep the rest of their product state above the package.

## Build a product advertisement

`LoomPeerAdvertisement` is where you publish peer identity plus app-specific capability hints.

Keep Loom-owned fields for transport-wide identity:

- `deviceID`
- `identityKeyID`
- `deviceType`
- optional presentation hints like `modelIdentifier`, `iconName`, and `machineFamily`

Keep product semantics in namespaced metadata keys:

```swift
import Foundation
import Loom

let deviceID = loadOrCreateStableDeviceID()
let identity = try LoomIdentityManager.shared.currentIdentity()

let advertisement = LoomPeerAdvertisement(
    deviceID: deviceID,
    identityKeyID: identity.keyID,
    deviceType: .mac,
    metadata: [
        "myapp.protocol": "1",
        "myapp.role": "host",
        "myapp.max-streams": "4",
    ]
)
```

`MirageKit` does exactly this. It keeps transport identity in the base advertisement and publishes stream capabilities like `mirage.max-streams` and codec support through namespaced metadata helpers.

## Advertise and accept sessions

```swift
let port = try await node.startAdvertising(
    serviceName: "My Mac",
    advertisement: advertisement
) { session in
    session.start(queue: .main)
}

print("Advertising on port \\(port)")
```

`LoomSession` is a thin wrapper around the accepted `NWConnection`. Start it on the queue you use for your networking runtime, then hand control to your own handshake or message layer.

If you want Loom to own the signed hello and encrypted post-handshake session, prefer authenticated advertising instead:

```swift
let ports = try await node.startAuthenticatedAdvertising(
    serviceName: "My Mac",
    helloProvider: {
        try await makeHelloRequest()
    }
) { session in
    print("Authenticated session ready over \\(session.transportKind)")
}

print("Direct transports:", ports)
```

`LoomAuthenticatedSession` requires the `loom.session-encryption.v1` feature and encrypts post-handshake control and data frames automatically. `startAuthenticatedAdvertising` also republishes Loom-owned direct transport hints so nearby peers do not need to carry direct listener ports in app metadata.

## Discover peers

```swift
let discovery = node.makeDiscovery()

discovery.onPeersChanged = { peers in
    for peer in peers {
        print("Found \\(peer.name) at \\(peer.endpoint)")
    }
}

discovery.startDiscovery()
```

Discovery only tells you that another peer exists and provides its `NWEndpoint` plus advertisement payload. It does not decide whether the peer is trusted or compatible with your product protocol.

## Connect with an authenticated session

```swift
let session = try await node.connect(
    to: peer.endpoint,
    using: .tcp,
    hello: try await makeHelloRequest()
)
```

After that point, your app owns the rest:

- protocol negotiation
- message framing
- approval UI
- reconnection policy
- stream, document, or UI semantics

If you publish multiple local or remote direct candidates, use ``LoomConnectionCoordinator`` with a ``LoomDirectConnectionPolicy`` so path ranking, transport preference, and bounded candidate racing stay in Loom instead of getting hardcoded in app code.

That split is the main thing to get right. If a type starts carrying app-specific naming, product roles, or CloudKit record assumptions, it probably belongs above Loom.

## Next steps

- <doc:LoomTutorials> is the step-by-step path through host, client, handshake, diagnostics, testing, and CloudKit lifecycle work.
- <doc:ModelYourIntegrationBoundary> explains the service-layer pattern Mirage uses around Loom.
- <doc:DesignYourPeerAdvertisement> shows how to evolve advertisement metadata without leaking product logic into Loom.
- <doc:AddTrustAndApproval> covers trust evaluation and manual approval flows.
- <doc:SharePeersWithCloudKit> covers the `LoomCloudKit` product and how to layer CloudKit-backed peer sharing on top of Loom.
- <doc:AddRemoteReachabilityAndBootstrap> covers remote signaling, STUN, Wake-on-LAN, and bootstrap control.
