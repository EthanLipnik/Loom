# Enable Cloud Peers and Remote Access

`LoomKit` does not force CloudKit or relay use, but it knows how to project those systems into the same peer model when you enable them in ``LoomContainerConfiguration``.

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

## Add Relay For Remote Joins

Set ``LoomContainerConfiguration/relay`` when you want remote hosting outside the local network:

```swift
let configuration = LoomContainerConfiguration(
    serviceName: "Example Mac",
    relay: relayConfiguration
)
```

Call ``LoomContext/startRemoteHosting(sessionID:publicHostForTCP:)`` when the local device should publish relay-backed reachability. LoomKit republishes the current peer record so `remoteAccessEnabled` and `relaySessionID` stay aligned with the runtime's real state.

## Connection Preference Order

When you ask LoomKit to connect to a ``LoomPeerSnapshot``, it uses a fixed resolution order:

1. Nearby direct connection when the peer is currently available locally.
2. Relay join when the peer publishes a `relaySessionID` and relay is configured.
3. Bootstrap remains explicit through ``LoomContext/wake(_:)`` and ``LoomContext/requestUnlock(_:username:password:)``.

That ordering matters because the app-facing API stays stable while LoomKit still prefers the fastest and lowest-latency path first.

## Trust Modes

Use ``LoomTrustMode`` to decide how much approval friction to keep:

- ``LoomTrustMode/manualOnly`` for fully explicit local trust decisions.
- ``LoomTrustMode/sameAccountAutoTrust`` to auto-trust peers from the same iCloud account.
- ``LoomTrustMode/shareAwareAutoTrust`` to auto-trust peers visible through accepted shares.

See <doc:AddRemoteAccessAndSharingWithLoomKit> for a full walkthrough.
