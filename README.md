# Loom

Loom is the networking layer for Apple-device apps that need to find each other, trust each other, connect fast, and keep working whether the peer is on the same desk or somewhere else entirely.

It is built for the messy real-world part of peer networking: discovery, identity, trust, direct sessions, remote reachability, bootstrap, and recovery. Your app keeps control of its own protocol and product logic. Loom handles the hard infrastructure underneath it.

Used in [MirageKit](https://github.com/EthanLipnik/MirageKit).

## What Loom Gives You

Loom packages the pieces most teams end up rebuilding themselves:

- local peer discovery with Bonjour
- peer-to-peer connectivity over AWDL
- direct sessions on top of `Network.framework`
- signed device identity
- trust and approval flows
- remote presence and candidate exchange
- STUN-based connectivity preflight
- Wake-on-LAN and SSH bootstrap
- credential-submission handoff for remote recovery flows
- optional CloudKit-backed peer registration, sharing, and trust
- diagnostics and instrumentation for the networking layer itself

That means you can spend your time on what makes your app different instead of building yet another peer stack from scratch.

## What You Can Build With It

Loom works well anywhere two Apple devices need to establish a reliable, trusted relationship before your app-specific protocol takes over.

Typical fits include:

- remote workspace and screen-sharing tools
- IDE companions that stream source text, diagnostics, and build output
- peer-to-peer sync apps for files, state, or project data
- remote control and automation tools
- local-first collaboration products
- operator dashboards and companion utilities across devices
- apps that need LAN-first connectivity with remote fallback

The payload does not matter to Loom. It can be video frames, text, files, telemetry, structured messages, or control commands. Loom’s job is to make the peer relationship work cleanly and securely.

## The Mental Model

Loom is not your app protocol.

Loom is the layer that answers:

- How do I discover peers?
- How do I identify them?
- How do I decide whether to trust them?
- How do I open and manage a session?
- How do I keep a peer reachable remotely?
- How do I wake or recover a peer before the main session begins?
- How do I observe and debug the network layer when it goes sideways?

Your app answers:

- What do we send?
- How is it encoded?
- What does it mean?
- What does the UI do with it?

That split is the value. Loom stays reusable because it stops at the networking and peer-coordination boundary.

## Core API

### `LoomNode`

The main entry point. `LoomNode` owns network configuration plus optional identity and trust dependencies, and gives you discovery and advertising.

### `LoomSession`

A lightweight wrapper around `NWConnection`. Loom does not impose a product-shaped protocol on top, so you can use the session for whatever your app needs to send.

### `LoomPeer`

A discovered peer, including its endpoint and advertisement.

### `LoomPeerAdvertisement`

Generic identity and device metadata plus an app-owned dictionary for your own discovery hints and conventions.

### `LoomIdentityManager`

Stable local identity, signing, and key material for trust, relay, and bootstrap workflows.

### `LoomTrustProvider` and `LoomTrustStore`

The trust layer. Use these to define approval rules, persistence, and user-controlled trust decisions.

### `LoomRelayClient`

Signed remote presence, candidate publication, and internet-facing session coordination.

### Bootstrap APIs

`LoomWakeOnLANClient`, `LoomSSHBootstrapClient`, `LoomBootstrapControlClient`, and `LoomBootstrapEndpointResolver` cover wake, reachability, and peer-preparation flows before a normal session starts.

### `LoomCloudKit`

`LoomCloudKitManager`, `LoomCloudKitPeerProvider`, `LoomCloudKitShareManager`, and `LoomCloudKitTrustProvider` add iCloud-backed peer coordination on top of the base framework.

### Diagnostics

`LoomDiagnostics` and `LoomInstrumentation` provide structured logs, typed errors, context, and timeline events for the networking layer.

## A Small Example

Create a node:

```swift
import Loom

let node = LoomNode(
    configuration: LoomNetworkConfiguration(
        serviceType: "_myapp._tcp",
        enablePeerToPeer: true
    ),
    identityManager: .shared
)
```

Advertise your app:

```swift
let identity = try LoomIdentityManager.shared.currentIdentity()

let advertisement = LoomPeerAdvertisement(
    deviceID: UUID(),
    identityKeyID: identity.keyID,
    deviceType: .mac,
    metadata: [
        "myapp.role": "builder",
        "myapp.version": "1"
    ]
)

let port = try await node.startAdvertising(
    serviceName: "My Mac",
    advertisement: advertisement
) { session in
    session.setStateUpdateHandler { state in
        print("incoming session:", state)
    }

    session.start(queue: .main)
}

print("advertising on port", port)
```

Discover peers:

```swift
let discovery = node.makeDiscovery()

discovery.onPeersChanged = { peers in
    for peer in peers {
        print("found:", peer.name, peer.endpoint)
    }
}

discovery.startDiscovery()
```

Dial a peer directly:

```swift
import Network

let connection = NWConnection(to: peer.endpoint, using: .tcp)
let session = node.makeSession(connection: connection)

session.setStateUpdateHandler { state in
    print("outgoing session:", state)
}

session.start(queue: .main)

session.send(content: Data("hello".utf8), completion: .contentProcessed { error in
    print("send finished:", error as Any)
})
```

From there, your protocol takes over.

## CloudKit Integration

If you want iCloud-backed peer coordination:

```swift
import LoomCloudKit

let cloudKit = LoomCloudKitManager(
    configuration: LoomCloudKitConfiguration(
        containerIdentifier: "iCloud.com.example.MyApp",
        peerRecordType: "MyAppPeer",
        peerZoneName: "MyAppPeerZone",
        shareTitle: "MyApp Peer Access",
        deviceIDKey: "com.example.myapp.deviceID"
    )
)

await cloudKit.initialize()

let provider = LoomCloudKitPeerProvider(cloudKitManager: cloudKit)
await provider.fetchPeers()
```

CloudKit naming is app-owned, so Loom fits naturally into products with their own naming, storage, and sharing conventions.

## Used In

- [MirageKit](https://github.com/EthanLipnik/MirageKit)

MirageKit uses Loom as its networking stack for discovery, trust, remote reachability, bootstrap, and CloudKit-backed peer coordination.

## Platforms

- macOS 14+
- iOS 17.4+
- visionOS 26+

## Development

```bash
swift build --package-path Loom
swift test --package-path Loom
```

## Documentation

- [DocC Documentation](https://ethanlipnik.github.io/Loom/documentation/loom/)

For the package boundary and runtime ownership model, see [Architecture.md](Architecture.md).
