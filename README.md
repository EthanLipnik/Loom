# Loom

Build high-throughput, low-latency Apple device-to-device features without building a networking stack from scratch.

Loom is a Swift package for apps that need to find other devices, connect directly, verify identity, make trust decisions, and keep working when the local network is not the whole story.

It is designed for Apple platforms, stays product-agnostic, and gives you a clean base for the part every multi-device app eventually has to build. The transport is built for high-throughput, low-latency data movement between Apple devices, and the package now includes a SwiftUI-first `LoomKit` surface for the apps that want a plug-and-play integration path.

If you want the default integration path, start with `LoomKit`. Drop down to `Loom` only when you need to own discovery, advertising, handshake policy, or transport composition yourself.

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

### SwiftUI-first package: `LoomKit`

- One shared `LoomContainer` per app or scene, modeled after SwiftData's `ModelContainer`
- Main-actor `LoomContext` injected through SwiftUI environment values
- Live `@LoomQuery` peer, connection, and transfer snapshots for SwiftUI lists
- Actor-backed `LoomConnectionHandle` values for message streams, file transfer, and custom multiplexed streams
- Optional CloudKit-backed peer merging and relay-backed remote reachability without changing the app-facing API

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

For most apps, the practical comparison is `LoomKit` on top of `Loom` versus `MultipeerConnectivity` or a MultipeerKit-style convenience layer.

The main question is whether you want a convenient local-session API only, or a SwiftUI-first path that still has identity, trust, diagnostics, and remote growth underneath it.

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

If you want the closest Loom equivalent to that convenience class of API, start with `LoomKit`.

If you need identity, trust, diagnostics, and a path beyond the local network, Loom's stack is the better foundation.

## Installation

Add Loom to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/EthanLipnik/Loom.git", from: "1.2.0")
]
```

Then add the product you want to your target:

For most apps, `LoomKit` should be the default dependency.

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "LoomKit", package: "Loom"),
        // Or drop down to the lower-level primitives:
        // .product(name: "Loom", package: "Loom"),
        // Add this if you want the optional terminal/session layer:
        // .product(name: "LoomShell", package: "Loom"),
        // Add this too if you want CloudKit-backed peer sharing or trust:
        // .product(name: "LoomCloudKit", package: "Loom"),
    ]
)
```

## SwiftUI-first quickstart

If you want something in the MultipeerKit class of ergonomics, start with `LoomKit`.

`LoomKit` is modeled more like SwiftData than like raw networking services:

- `LoomContainer` owns the runtime
- `LoomContext` is the main-actor action surface
- `@LoomQuery` gives SwiftUI live snapshots
- `LoomConnectionHandle` owns the long-lived async streams

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
        .task {
            for await connection in loomContext.incomingConnections {
                Task {
                    for await message in connection.messages {
                        print("Received", message.count, "bytes")
                    }
                }
            }
        }
    }
}
```

That is the intended default. You can add CloudKit-backed peer sharing, trust, and relay publication through `LoomContainerConfiguration` without changing the SwiftUI-facing API shape.

## Build from primitives when needed

If you need full control over discovery, advertising, or handshake policy, drop down to `Loom`.

The main type there is `LoomNode`. It owns discovery, advertising, sessions, and the identity and trust collaborators you inject into it.

```swift
import Loom

let node = LoomNode(
    configuration: LoomNetworkConfiguration(
        serviceType: "_myapp._tcp",
        enablePeerToPeer: true
    ),
    identityManager: LoomIdentityManager.shared
)

let discovery = node.makeDiscovery()
discovery.onPeersChanged = { peers in
    print("Peers:", peers.map(\.name))
}
discovery.startDiscovery()
```

Use `LoomNode` when you want to own the full runtime boundary yourself. Use `LoomKit` when you want the repo to feel closer to SwiftUI + SwiftData.

## The simple mental model

1. `LoomKit` is the app-facing path for SwiftUI apps.
2. `LoomNode` is the lower-level transport composition root.
3. `LoomConnectionHandle` and `LoomAuthenticatedSession` are the live data paths.
4. Your app still owns protocol semantics, product policy, and UI behavior.

That split is what keeps Loom reusable instead of turning it into someone else's app framework.

## Requirements

- Swift 6.2+
- macOS 14+
- iOS 17.4+
- visionOS 26+

## Learn more

If you want the deeper material, go to the docs:

- [LoomKit Documentation](https://ethanlipnik.github.io/Loom/documentation/loomkit/)
- [Loom Documentation](https://ethanlipnik.github.io/Loom/documentation/loom/)
- [LoomShell Documentation](https://ethanlipnik.github.io/Loom/documentation/loomshell/)
- [Architecture notes](Architecture.md)

## Development

```bash
swift build
swift test --scratch-path .build-local
```
