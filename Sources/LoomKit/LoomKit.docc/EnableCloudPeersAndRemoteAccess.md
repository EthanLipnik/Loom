# Enable Cloud Peers and Remote Access

`LoomKit` does not force CloudKit, signaling, or shared-host mode, but it knows how to project those systems into the same peer model when you enable them in ``LoomContainerConfiguration``.

## Add CloudKit To Merge Peer Visibility

Set ``LoomContainerConfiguration/cloudKit`` when you want peer records to survive beyond a local Bonjour session:

```swift
let configuration = LoomContainerConfiguration(
    serviceName: "Example Mac",
    deviceIDSuiteName: "group.com.example.shared",
    cloudKit: .init(containerIdentifier: "iCloud.com.example.shared")
)
```

When CloudKit is enabled, LoomKit merges nearby peers and CloudKit-visible peers into one ``LoomPeerSnapshot`` keyed by device identifier.

## Add Signaling For Remote Joins

Set ``LoomContainerConfiguration/relay`` when you want signaling-backed remote reachability outside the local network:

```swift
let configuration = LoomContainerConfiguration(
    serviceName: "Example Mac",
    relay: relayConfiguration
)
```

Call ``LoomContext/publishRemoteReachability(sessionID:publicHostForTCP:)`` when the local device should publish signaling-backed reachability. LoomKit republishes the current peer record so `remoteAccessEnabled` and `relaySessionID` stay aligned with the runtime's real state.

## Connection Preference Order

When you ask LoomKit to connect to a ``LoomPeerSnapshot``, it uses a fixed resolution order:

1. Nearby direct connection when the peer is currently available locally.
2. Signaling join when the peer publishes a `relaySessionID` and signaling is configured.
3. Bootstrap remains explicit through ``LoomContext/bootstrap`` when a peer publishes recovery capability.

That ordering matters because the app-facing API stays stable while LoomKit still prefers the fastest and lowest-latency path first.

Use ``LoomContainerConfiguration/enabledDirectTransports`` when a container should publish only a subset of Loom's direct transports. Use ``LoomContainerConfiguration/directConnectionPolicy`` when a container should keep Loom's resolution behavior but customize path order, transport order, local candidate racing, or a local-discovery host override.

Use ``LoomContainerConfiguration/ports`` when a container needs fixed listener ports. TCP, UDP, and QUIC default to `0`, which lets the system assign available ephemeral ports. Overlay probing defaults to Loom's overlay probe port when ``LoomContainerConfiguration/overlayDirectory`` is enabled and the overlay configuration omits its own `probePort`:

```swift
let configuration = LoomContainerConfiguration(
    serviceName: "Example Mac",
    ports: LoomKitPortConfiguration(
        udpPort: 9951,
        quicPort: 9952,
        overlayProbePort: 9953
    ),
    overlayDirectory: LoomOverlayDirectoryConfiguration(
        seedProvider: {
            [LoomOverlaySeed(host: "example-mac.tailnet.example")]
        }
    )
)
```

## Trust Modes

Use ``LoomTrustMode`` to decide how much approval friction to keep:

- ``LoomTrustMode/manualOnly`` for fully explicit local trust decisions.
- ``LoomTrustMode/sameAccountAutoTrust`` to auto-trust peers from the same iCloud account.
- ``LoomTrustMode/shareAwareAutoTrust`` to auto-trust peers visible through accepted shares.

See <doc:AddRemoteAccessAndSharingWithLoomKit> for a full walkthrough.

## macOS Shared Host Mode

If multiple apps in one App Group should publish and connect through one shared Loom runtime, set ``LoomContainerConfiguration/appGroup`` instead of spinning up independent network owners in each process.

That changes the runtime topology, not the app-facing API:

- SwiftUI still reads peers through ``LoomQuery``.
- Actions still go through ``LoomContext``.
- Connections still arrive as ``LoomConnectionHandle`` values.

See <doc:ShareOneLoomKitRuntimeAcrossApps> for the LoomKit-first setup flow.
