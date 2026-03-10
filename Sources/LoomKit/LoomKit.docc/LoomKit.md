# ``LoomKit``

Build SwiftUI-first Apple device communication on top of Loom's high-throughput, low-latency transport stack.

## Overview

`LoomKit` is the high-level product for apps that want a container/context/query API rather than wiring `LoomNode`, discovery, CloudKit, and relay pieces by hand.

Use it when you want:

- one shared `LoomContainer` per app or scene
- a main-actor `LoomContext` injected through SwiftUI environment values
- live `@LoomQuery` peer, connection, and transfer snapshots in SwiftUI views
- actor-backed `LoomConnectionHandle` values for messages, file transfer, and custom multiplexed streams
- optional CloudKit-backed peer merging and relay-backed remote hosting without changing the app-facing API shape

`LoomKit` sits above `Loom`:

- `Loom` owns discovery, authenticated transport, trust primitives, relay rendezvous, and bootstrap helpers
- `LoomKit` owns the SwiftUI-facing runtime model, unified peer snapshots, and the app-friendly async handles

The documentation is organized the same way:

- start with <doc:AdoptLoomKitInSwiftUI> for the mental model
- use <doc:LoomKitTutorials> for step-by-step integrations
- drop into symbol reference pages when you need exact API behavior

## Topics

### Essentials

- <doc:AdoptLoomKitInSwiftUI>
- <doc:LoomKitTutorials>
- ``LoomContainer``
- ``LoomContext``
- ``LoomQuery``
- ``LoomContainerConfiguration``
- ``LoomConnectionHandle``
- ``LoomPeerSnapshot``
- ``LoomConnectionSnapshot``
- ``LoomTransferSnapshot``
- ``LoomTrustMode``

### Guides

- <doc:QueryPeersConnectionsAndTransfers>
- <doc:HandleConnectionsAndTransfers>
- <doc:EnableCloudPeersAndRemoteAccess>
