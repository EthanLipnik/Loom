# Add Remote Reachability and Bootstrap

Remote support in Loom is intentionally composable. You can adopt as much or as little of it as your product needs.

The broad pattern looks like this:

1. probe whether direct external connectivity is possible
2. resolve overlay-reachable peers when your network provides stable host seeds
3. publish remote presence and candidates
4. expose bootstrap metadata for recovery paths
5. attempt deterministic recovery in app-owned policy order

That is also how `MirageKit` uses Loom. Remote reachability, CloudKit peer records, and SSH or Wake-on-LAN recovery are layered on top of the same local discovery and identity model.

## Start with STUN preflight

Use ``LoomSTUNProbe`` to see whether the current network can expose a usable mapped endpoint.

```swift
let stunResult = await LoomSTUNProbe.run()

guard stunResult.reachable,
      let address = stunResult.mappedAddress,
      let port = stunResult.mappedPort else {
    return
}

let candidate = LoomRemoteCandidate(
    transport: .quic,
    address: address,
    port: port
)
```

That gives your app concrete information about whether direct remote connectivity is even worth advertising.

## Add an overlay peer directory when you already have host seeds

Some products run on overlay or VPN-style networks where devices already have stable names or IP addresses. In that case, use ``LoomOverlayDirectory`` with an app-owned seed provider instead of treating those peers as remote signaling-only.

```swift
let overlayDirectory = LoomOverlayDirectory(
    configuration: LoomOverlayDirectoryConfiguration(
        probePort: Loom.defaultOverlayProbePort,
        refreshInterval: .seconds(30),
        probeTimeout: .seconds(2),
        seedProvider: {
            [
                LoomOverlaySeed(host: "studio-mac.tailnet.example"),
                LoomOverlaySeed(host: "100.64.0.25"),
            ]
        }
    )
)

overlayDirectory.start()
```

Each seed is just a host hint. Loom then probes that host’s dedicated overlay listener, validates the Loom advertisement payload, and builds regular ``LoomPeer`` values from the response. That keeps the transport generic:

- your network provider owns device reachability and naming
- Loom owns Loom-native peer identity and transport metadata
- your app still decides which seeds to trust and when to refresh them

The important architectural boundary is that overlay discovery is still direct connectivity. It is not CloudKit presence and it is not remote signaling.

If your overlay is Tailscale, that usually means your seed provider returns MagicDNS host names or stable tailnet IP addresses. Loom does not integrate with the Tailscale control plane directly. It only probes the hosts your app chooses to trust and publish. For a more concrete Tailscale and custom-inventory walkthrough, see <doc:UseTailscaleAndCustomOverlays>.

## Publish remote presence

Use ``LoomRemoteSignalingClient`` with app-owned signaling credentials.

```swift
let signalingClient = LoomRemoteSignalingClient(configuration: signalingConfiguration)

try await signalingClient.advertisePeerSession(
    sessionID: sessionID,
    peerID: deviceID,
    acceptingConnections: true,
    peerCandidates: [candidate]
)
```

The important ownership split is the same as everywhere else in Loom:

- Loom signs and sends the signaling requests
- your app owns the session identifier, endpoint, Worker deployment, and policy for when remote access is exposed

## Publish bootstrap metadata separately

Bootstrap recovery is not the same thing as the primary session transport.

Use ``LoomBootstrapMetadata`` to publish optional recovery channels such as:

- SSH endpoints
- a bootstrap control port
- a bootstrap control shared secret
- a preferred SSH port
- pinned SSH host-key fingerprints
- a Wake-on-LAN payload

```swift
let bootstrapMetadata = LoomBootstrapMetadata(
    enabled: true,
    supportsPreloginDaemon: true,
    endpoints: [
        .init(host: "host.example.com", port: 22, source: .user),
        .init(host: "192.168.1.25", port: 22, source: .auto),
    ],
    sshPort: 22,
    controlPort: 9849,
    controlAuthSecret: "base64-shared-secret",
    sshHostKeyFingerprints: ["SHA256:..."],
    wakeOnLAN: .init(
        macAddress: "AA:BB:CC:DD:EE:FF",
        broadcastAddresses: ["192.168.1.255"]
    )
)
```

`MirageKit` persists this kind of information alongside peer records so remote recovery can happen without overloading the local session protocol.

## Resolve endpoints deterministically

Before attempting recovery, normalize the endpoint list with ``LoomBootstrapEndpointResolver``.

```swift
let orderedEndpoints = LoomBootstrapEndpointResolver.resolve(bootstrapMetadata.endpoints)
```

That gives you a stable order:

1. user-entered endpoints
2. auto-discovered endpoints
3. last-seen cached endpoints

That deterministic order is important when you want retries to feel predictable across launches.

## Use Wake-on-LAN or SSH when needed

Loom also ships focused clients for the other common recovery steps:

- ``LoomDefaultWakeOnLANClient`` sends magic packets using ``LoomWakeOnLANInfo``
- ``LoomDefaultSSHBootstrapClient`` requires an explicit ``LoomSSHServerTrustConfiguration`` and validates either OpenSSH host certificates against trusted host CAs or raw host keys against pinned SHA256 fingerprints

Those clients are deliberately narrow. Your app still decides:

- when to wake a device
- which credentials can be submitted
- how many retries are acceptable
- how recovery status maps into UI

That is the right split. Bootstrap logic is transport-adjacent, but the policy is still product-owned.
