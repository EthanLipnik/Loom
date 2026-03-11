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
- direct and relay-backed session coordination
- Wake-on-LAN, SSH, and control-channel bootstrap flows
- diagnostics and instrumentation for the networking layer

Your app still owns payload schemas, user experience, and product policy.

## Topics

### Essentials

- <doc:LoomTutorials>
- <doc:GettingStarted>
- <doc:ModelYourIntegrationBoundary>
- <doc:DesignYourPeerAdvertisement>
- <doc:AddTrustAndApproval>
- <doc:SharePeersWithCloudKit>
- <doc:AddRemoteReachabilityAndBootstrap>
- <doc:UseTailscaleAndCustomOverlays>
- <doc:TransferLargeObjects>
- ``LoomNode``
- ``LoomSession``
- ``LoomAuthenticatedSession``
- ``LoomConnectionCoordinator``
- ``LoomTransferEngine``
- ``LoomPeer``
- ``LoomPeerAdvertisement``
- ``LoomNetworkConfiguration``

### Identity And Trust

- ``LoomIdentityManager``
- ``LoomTrustProvider``
- ``LoomTrustStore``

### Remote Connectivity

- ``LoomOverlayDirectory``
- ``LoomOverlayDirectoryConfiguration``
- ``LoomOverlaySeed``
- ``LoomRelayClient``
- ``LoomSTUNProbe``

### Bootstrap

- ``LoomBootstrapEndpointResolver``
- ``LoomBootstrapControlClient``
- ``LoomWakeOnLANClient``
- ``LoomSSHBootstrapClient``

### Diagnostics

- ``LoomDiagnostics``
- ``LoomInstrumentation``
