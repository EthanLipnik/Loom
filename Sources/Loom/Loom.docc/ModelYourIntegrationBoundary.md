# Model Your Integration Boundary

The most important Loom design rule is that it should remain the substrate, not the whole product runtime.

`MirageKit` is a useful reference because it does not try to force product behavior into Loom. Its host and client services each own a ``LoomNode``, but they keep the rest of the stack outside the package:

- handshake schema and negotiation
- stream and window semantics
- app-specific persistent state
- CloudKit registration policy
- approval UI and product rules

## Own one node per runtime surface

In practice, a higher-level service usually owns:

- one ``LoomNode``
- one app-owned stable device identifier
- one app-owned advertisement builder
- zero or one trust provider
- the code that maps `NWConnection` or ``LoomSession`` into your protocol

That keeps Loom focused on transport primitives while your package or app owns policy.

```swift
import Loom

@MainActor
final class MyHostService {
    private let deviceID: UUID
    private let node: LoomNode

    init(deviceID: UUID, trustProvider: (any LoomTrustProvider)? = nil) {
        self.deviceID = deviceID
        node = LoomNode(
            configuration: LoomNetworkConfiguration(
                serviceType: "_myapp._tcp",
                enablePeerToPeer: true
            ),
            identityManager: LoomIdentityManager.shared,
            trustProvider: trustProvider
        )
    }
}
```

That is much easier to reason about than treating Loom as a global singleton.

## Keep app defaults above Loom

Loom provides defaults like ``Loom/serviceType`` and ``LoomNetworkConfiguration/default``, but shipping apps usually replace them.

`MirageKit` does this in both host and client services. It rewrites the default service type to an app-specific one and persists its own stable device ID in product code. That is the right direction: service names, product roles, and persisted identity policy are app concerns.

Good examples of app-owned state:

- Bonjour service type
- device display name
- stable device ID storage
- product protocol version
- approval timeout and UX
- CloudKit record naming

## Keep product protocol above Loom

``LoomSession`` intentionally stays thin. It wraps the connection lifecycle, but it does not define:

- your handshake
- your message framing
- your reconnect semantics
- your stream multiplexing

`MirageKit` uses Loom for the accepted session and then immediately layers its own hello exchange, signature validation, feature negotiation, and media setup above that session. That separation is why Loom remains reusable.

If you are debating whether a type belongs in Loom, ask a simple question:

Would another app with a different wire protocol still want this exact abstraction?

If the answer is no, keep it above Loom.

## A practical checklist

When you introduce Loom to a product, keep this split:

- Loom owns discovery, identity primitives, trust interfaces, signaling helpers, STUN, bootstrap transports, and diagnostics.
- Your app owns message schemas, approval UX, CloudKit schema choices, protocol negotiation, and any domain-specific capability model.

That boundary makes the rest of the tutorial set easier to apply:

- <doc:DesignYourPeerAdvertisement>
- <doc:AddTrustAndApproval>
- <doc:SharePeersWithCloudKit>
- <doc:AddRemoteReachabilityAndBootstrap>
