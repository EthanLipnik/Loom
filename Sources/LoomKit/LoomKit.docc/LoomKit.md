# ``LoomKit``

Build SwiftUI-first Apple device communication on top of Loom's high-throughput, low-latency transport stack.

## Overview

`LoomKit` is the high-level product for apps that want a container/context/query API rather than wiring `LoomNode`, discovery, CloudKit, and signaling pieces by hand.

Use it when you want:

- one shared `LoomContainer` per app or scene
- a main-actor `LoomContext` injected through SwiftUI environment values
- live `@LoomQuery` peer, connection, and transfer snapshots in SwiftUI views
- actor-backed `LoomConnectionHandle` values for messages, file transfer, and custom multiplexed streams
- optional CloudKit-backed peer merging and signaling-backed remote reachability publication without changing the app-facing API shape
- optional App Group-backed shared hosting on macOS when multiple apps should behave like one network host

`LoomKit` sits above `Loom`:

- `Loom` owns discovery, authenticated transport, trust primitives, signaling rendezvous, and bootstrap helpers
- `LoomKit` owns the SwiftUI-facing runtime model, unified peer snapshots, and the app-friendly async handles

The documentation is organized the same way:

- start with <doc:AdoptLoomKitInSwiftUI> for the mental model
- use <doc:LoomKitTutorials> for step-by-step integrations
- drop into symbol reference pages when you need exact API behavior

## Which Product Should I Use?

- Use `LoomKit` when you want a SwiftUI-first, peer-centric runtime with one `LoomContainer`, a `LoomContext`, live queries, and connection handles.
- Use `Loom` when you want to wire discovery, advertising, sessions, trust, or signaling behavior yourself at a lower level.
- Add `LoomCloudKit` when peer visibility or trust should flow through CloudKit-backed records and shares.
- Use LoomKit's App Group configuration only for macOS setups where multiple apps should share one underlying Loom runtime.
- Add `LoomShell` only when your product needs shell/bootstrap-oriented recovery flows above the core transport layer.

## Platform Notes

- Standalone `Loom` and `LoomKit` runtimes are intended for `macOS`, `iOS`, and `visionOS`.
- LoomKit App Group mode is macOS-only by design.
- Bootstrap and recovery features are optional. A peer can fully participate in LoomKit messaging and file transfer without publishing any bootstrap metadata.

> Important: Your app's Info.plist must declare `NSBonjourServices` (with your service type) and `NSLocalNetworkUsageDescription` for discovery to work. Without these keys, Bonjour operations fail with error `-65555 (NoAuth)`. See the Loom documentation article "Configure Local Network Access" for the full setup.

## Topics

### Essentials

- <doc:AdoptLoomKitInSwiftUI>
- <doc:LoomKitTutorials>
- ``LoomContainer``
- ``LoomContext``
- ``LoomQuery``
- ``LoomContainerConfiguration``
- ``LoomKitPortConfiguration``
- ``LoomConnectionHandle``
- ``LoomPeerSnapshot``
- ``LoomConnectionSnapshot``
- ``LoomTransferSnapshot``
- ``LoomTrustMode``

### Guides

- <doc:QueryPeersConnectionsAndTransfers>
- <doc:HandleConnectionsAndTransfers>
- <doc:EnableCloudPeersAndRemoteAccess>
- <doc:ShareOneLoomKitRuntimeAcrossApps>
