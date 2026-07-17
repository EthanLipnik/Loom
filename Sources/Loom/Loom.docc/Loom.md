# ``Loom``

Loom is a product-agnostic networking package for Apple platforms that handles discovery, identity, trust, session establishment, remote reachability, and bootstrap workflows between peers.

## Overview

Use Loom when your app needs to find another Apple device, decide whether to trust it, and establish a session without baking product-specific assumptions into the transport layer.

If you want a SwiftUI-first container/context/query API, start with the separate `LoomKit` product. This documentation set focuses on the product-agnostic primitives underneath that higher-level surface.

The important architectural choice is that Loom stops at the networking boundary. Real apps still need to decide:

- which Bonjour service type to advertise
- how to shape peer metadata
- how trust decisions map to product policy
- whether CloudKit, remote signaling, or bootstrap recovery belong in the product

`MirageKit` is a good example of this split. It owns the handshake schema, stream semantics, CloudKit record lifecycle, and UI policy, while Loom stays focused on discovery, identity, trust primitives, and transport helpers.

Loom owns the peer relationship and connectivity infrastructure:

- discovery over Bonjour and peer-to-peer transports
- stable device identity and signing
- trust-policy integration and persistence
- direct and remote signaling-backed session coordination
- Wake-on-LAN, SSH, and control-channel bootstrap flows
- diagnostics and instrumentation for the networking layer

Your app still owns payload schemas, user experience, and product policy.

Authenticated Loom sessions also expose transport-facing metadata that higher-level products can observe without reaching under the session boundary: a stable session identifier, explicit bootstrap progress phases before the session becomes ready, the current remote endpoint, async snapshots of path changes on the underlying connection, and queued unreliable stream sends for media-style traffic that preserve submission order without waiting on each Network.framework completion before returning. Callers with a related payload group can use ``LoomMultiplexedStream/sendUnreliableQueuedBatch(_:profile:)`` and ``LoomQueuedUnreliableBatchItem`` to cross stream, encryption, and transport queue admission once while retaining per-payload scheduling metadata and completion. Ordered unreliable sends support queue profiles so latency-sensitive media can keep shallow buffers while explicit throughput probes can request deeper transport queues to find the true loss point of a path. Higher layers can also reset one queue profile without closing the stream, which lets explicit throughput probes discard stale queued traffic after they hit an overload boundary.

## Topics

### Essentials

- <doc:LoomTutorials>
- <doc:GettingStarted>
- <doc:ConfigureLocalNetworkAccess>
- <doc:ModelYourIntegrationBoundary>
- <doc:DesignYourPeerAdvertisement>
- <doc:AddTrustAndApproval>
- <doc:SharePeersWithCloudKit>
- <doc:AddRemoteReachabilityAndBootstrap>
- <doc:UseTailscaleAndCustomOverlays>
- <doc:TransferLargeObjects>
- ``LoomNode``
- ``LoomConnection``
- ``LoomAuthenticatedSession``
- ``LoomConnectionCoordinator``
- ``LoomTransferEngine``
- ``LoomPeer``
- ``LoomPeerAdvertisement``
- ``LoomNetworkConfiguration``

### Queued Unreliable Sending

- ``LoomMultiplexedStream``
- ``LoomQueuedUnreliableBatchItem``
- ``LoomQueuedUnreliableSendOptions``
- ``LoomQueuedUnreliableSendProfile``
- ``LoomQueuedUnreliableSendDrop``

### Identity And Trust

- ``LoomIdentityManager``
- ``LoomTrustProvider``
- ``LoomTrustStore``

### Remote Connectivity

- <doc:BuildASignalingService>
- ``LoomOverlayDirectory``
- ``LoomOverlayDirectoryConfiguration``
- ``LoomOverlaySeed``
- ``LoomRemoteSignalingClient``
- ``LoomSTUNProbe``

### Bootstrap

- ``LoomBootstrapEndpointResolver``
- ``LoomBootstrapControlClient``
- ``LoomBootstrapControlCommandPayload``
- ``LoomWakeOnLANClient``
- ``LoomSSHBootstrapClient``

### Diagnostics

- ``LoomDiagnostics``
- ``LoomInstrumentation``
