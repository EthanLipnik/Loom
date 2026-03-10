# Loom

Build Apple-native device-to-device features without building a networking stack from scratch.

Loom is a Swift package for apps that need to find other devices, connect directly, verify identity, make trust decisions, and keep working when the local network is not the whole story.

It is designed for Apple platforms, stays product-agnostic, and gives you a clean base for the part every multi-device app eventually has to build.

Used in [MirageKit](https://github.com/EthanLipnik/MirageKit).

## Why developers use Loom

If you are building something that talks to another device, you usually end up piecing together:

- discovery
- direct connections
- identity
- trust
- remote reachability
- diagnostics

Loom gives you those building blocks as a reusable Swift package.

That means you can focus on your app's behavior instead of spending weeks rebuilding networking plumbing.

## What you can build with it

Loom is a good fit for things like:

- Mac and iPhone companion apps
- local-first collaboration tools
- device control surfaces
- host and client apps on the same network
- pro apps that need to discover and connect to nearby machines
- products that start local but eventually need remote coordination

## What Loom gives you

### Core package: `Loom`

- Nearby peer discovery over Bonjour, including peer-to-peer support
- Direct sessions built on `Network.framework`
- Stable device identity and key management
- Pluggable trust policy and local trust storage
- Remote reachability support with relay presence and network probing
- Bootstrap tools for flows like Wake-on-LAN and SSH handoff
- Diagnostics and instrumentation hooks

### App-facing shell package: `LoomShell`

- Loom-native interactive shell sessions over authenticated Loom transport
- macOS PTY host runtime for building a native host app quickly
- Connection policy that prefers Loom-native direct paths before SSH fallback
- Relay publication helpers for introducer-only remote access
- OpenSSH fallback runtime with password or private-key authentication
- Connection attempt reports that are usable in product UI

### Optional package: `LoomCloudKit`

- CloudKit-backed peer sharing
- CloudKit-backed trust decisions
- Share and participant management for multi-device apps

## What Loom does not do

This part matters, especially if you are new to this space.

Loom is the transport layer, not the product layer.

Loom does not decide:

- your app's protocol
- your message schema
- your UI
- your product roles
- your CloudKit schema naming

Your app owns those decisions. Loom gives you the network foundation underneath them.

## How Loom compares

If you are deciding between `Loom` and `MultipeerConnectivity`, the main question is whether you want a convenient local-session API or a foundation you can keep building on.

| Capability | `Loom` | `MultipeerConnectivity` |
| --- | --- | --- |
| Networking model | Bonjour discovery plus direct `Network.framework` sessions you can reason about and extend | High-level Apple-managed local peer sessions |
| Identity model | Stable device identity and signed session setup are first-class | Peer identity is mostly session-oriented and app-specific trust modeling is left to you |
| Trust decisions | Explicit trust providers and local trust storage | Invitation and certificate hooks exist, but there is no Loom-style trust layer to plug into your product |
| Remote growth path | Includes relay/STUN support and optional `LoomCloudKit` peer sharing and trust | Focused on nearby/local networking with no built-in remote reachability story |
| Product boundaries | Keeps your protocol, schema, and app roles above the transport layer | Easy to start, but the framework shape tends to leak into the rest of your app architecture |
| Diagnostics and operability | Built-in diagnostics and instrumentation hooks | Much thinner observability surface |
| Best fit | Apps that need a durable multi-device architecture, not just nearby messaging | Quick local-first prototypes or simple nearby collaboration |

If your app only needs nearby discovery and a session quickly, `MultipeerConnectivity` is fine.

If you need identity, trust, diagnostics, and a path beyond the local network, `Loom` is the better foundation.

## Installation

Add Loom to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/EthanLipnik/Loom.git", branch: "main")
]
```

Then add the product you want to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Loom", package: "Loom"),
        // Add this to build a terminal or SSH app on top of Loom:
        // .product(name: "LoomShell", package: "Loom"),
        // Add this too if you want CloudKit-backed peer sharing or trust:
        // .product(name: "LoomCloudKit", package: "Loom"),
    ]
)
```

## Basic usage

The main type to understand is `LoomNode`.

Think of `LoomNode` as the networking hub for one part of your app. It owns discovery, advertising, sessions, and the identity and trust collaborators you inject into it.

### 1. Create a node

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

If you are just getting started, that is the right mental model:

- choose a Bonjour service type for your app
- decide whether peer-to-peer browsing should be enabled
- create one `LoomNode` for the runtime surface you are building

### 2. Advertise your device

```swift
import Foundation

let identity = try LoomIdentityManager.shared.currentIdentity()

let advertisement = LoomPeerAdvertisement(
    deviceID: UUID(),
    identityKeyID: identity.keyID,
    deviceType: .mac,
    metadata: [
        "myapp.role": "host",
        "myapp.protocol": "1",
    ]
)

let port = try await node.startAdvertising(
    serviceName: "My Mac",
    advertisement: advertisement
) { session in
    session.start(queue: .main)
}

print("Advertising on port \(port)")
```

This makes your device discoverable and hands you a `LoomSession` when someone connects.

In a real app, keep `deviceID` stable instead of generating a new `UUID()` every launch. Your identity story gets much simpler if the device can be recognized over time.

### 3. Browse for peers

```swift
let discovery = node.makeDiscovery()

discovery.onPeersChanged = { peers in
    for peer in peers {
        print("Found \(peer.name) at \(peer.endpoint)")
    }
}

discovery.startDiscovery()
```

At this stage, you are discovering peers and reading their advertised metadata. Your app still decides whether a peer is compatible, trusted, or worth connecting to.

### 4. Open a session

```swift
import Network

let connection = NWConnection(to: peer.endpoint, using: .tcp)
let session = node.makeSession(connection: connection)

session.setStateUpdateHandler { state in
    print("Session state:", state)
}

session.start(queue: .main)
```

Once the session exists, your app takes over again. That is where your own protocol, handshake, message framing, and product logic should live.

## The simple mental model

If you only remember one thing, make it this:

1. `LoomNode` manages discovery and connections.
2. `LoomPeerAdvertisement` tells other devices what you want them to know.
3. `LoomSession` is the live connection.
4. Your app owns everything above that line.

That split is what keeps Loom reusable instead of turning it into someone else's app framework.

## Requirements

- Swift 6.2+
- macOS 14+
- iOS 17.4+
- visionOS 26+

## Learn more

If you want the deeper material, go to the docs:

- [Loom Documentation](https://ethanlipnik.github.io/Loom/documentation/loom/)
- [LoomShell Documentation](https://ethanlipnik.github.io/Loom/documentation/loomshell/)
- [Build A Shell App On Loom](https://ethanlipnik.github.io/Loom/documentation/loomshell/buildashellapponloom/)
- [Architecture notes](Architecture.md)

## Development

```bash
swift build
swift test --scratch-path .build-local
```
