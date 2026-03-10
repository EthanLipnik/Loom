# Design Your Peer Advertisement

``LoomPeerAdvertisement`` is one of the main extension points in Loom.

Use it for two things:

- transport-level identity and presentation fields that Loom already understands
- an app-owned metadata dictionary for everything product-specific

The mistake to avoid is letting ad hoc string keys spread across the codebase. `MirageKit` avoids that by centralizing its advertisement schema in one helper type and keeping product keys namespaced under `mirage.*`.

## Use Loom-owned fields for shared identity

These fields are worth filling when you have them:

- `deviceID`
- `identityKeyID`
- `deviceType`
- `modelIdentifier`
- `iconName`
- `machineFamily`
- `directTransports` when you need Loom-owned TCP or QUIC listener hints

Those values are useful across discovery, trust evaluation, and CloudKit registration.

```swift
import Loom

let identity = try LoomIdentityManager.shared.currentIdentity()

let advertisement = LoomPeerAdvertisement(
    deviceID: deviceID,
    identityKeyID: identity.keyID,
    deviceType: .mac,
    modelIdentifier: "Mac14,15",
    metadata: [
        "myapp.protocol": "1",
        "myapp.max-streams": "4",
    ]
)
```

Do not push direct listener ports into app metadata. Loom has a first-class `directTransports` field for that, and ``LoomNode/startAuthenticatedAdvertising(serviceName:helloProvider:onSession:)`` updates it automatically for the listeners Loom owns.

## Centralize product metadata

`MirageKit` uses a dedicated metadata helper to build and decode its product keys. That is the pattern to copy.

```swift
import Foundation
import Loom

enum MyPeerAdvertisementMetadata {
    private static let protocolKey = "myapp.protocol"
    private static let maxStreamsKey = "myapp.max-streams"
    private static let supportsHDRKey = "myapp.supports-hdr"

    static func makeHostAdvertisement(
        deviceID: UUID,
        identityKeyID: String
    ) -> LoomPeerAdvertisement {
        LoomPeerAdvertisement(
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceType: .mac,
            metadata: [
                protocolKey: "1",
                maxStreamsKey: "4",
                supportsHDRKey: "1",
            ]
        )
    }

    static func maxStreams(from advertisement: LoomPeerAdvertisement) -> Int {
        Int(advertisement.metadata[maxStreamsKey] ?? "1") ?? 1
    }

    static func supportsHDR(in advertisement: LoomPeerAdvertisement) -> Bool {
        advertisement.metadata[supportsHDRKey] == "1"
    }
}
```

Benefits of this approach:

- reserved Loom keys stay untouched
- parsing logic lives in one place
- you can change defaults without chasing raw strings
- future protocol migrations stay explicit

## Namespace and version your keys

Treat advertisement metadata like a public wire surface.

Good habits:

- prefix keys with your app or package name
- keep values simple and string-serializable
- include a product protocol or schema version
- make missing keys safe by design

`LoomPeerAdvertisement` already protects reserved TXT record keys when it encodes with ``LoomPeerAdvertisement/toTXTRecord()``. Your job is to make the app-specific portion stable and easy to evolve.

## Decode from the advertisement, not from loose TXT keys

Prefer helpers that accept a full ``LoomPeerAdvertisement`` instead of reading raw Bonjour TXT records in multiple places. That keeps the transport parsing boundary small:

- Loom decodes discovery payloads into ``LoomPeerAdvertisement``
- your app decodes product semantics from that advertisement

That is exactly how `MirageKit` exposes convenience accessors like `mirageMaxStreams` while keeping the underlying metadata schema centralized.

## Keep the metadata small and intentional

Advertisements should help peers decide whether they can talk, not replace your protocol.

Good use cases:

- product protocol version
- codec or capability hints
- device role
- presentation hints for UI

Bad use cases:

- large configuration payloads
- secrets
- anything that must be authenticated separately before use

If the value materially affects trust or security, validate it again inside your real handshake.
