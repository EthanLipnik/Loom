# Share Peers with CloudKit

Use the `LoomCloudKit` product when your app needs an app-owned peer directory and share-based trust on top of local discovery.

`MirageKit` uses CloudKit in exactly that role. It does not replace Loom's local networking. Instead, it publishes peer records, carries advertisement data into CloudKit, and uses share membership as another trust signal.

## Initialize CloudKit early

Start with `LoomCloudKitConfiguration` and `LoomCloudKitManager`.

```swift
import Loom
import LoomCloudKit

let configuration = LoomCloudKitConfiguration(
    containerIdentifier: "iCloud.com.example.myapp"
)

let cloudKitManager = LoomCloudKitManager(configuration: configuration)
await cloudKitManager.initialize()
```

The manager defers container creation until `initialize()` so your app can tolerate missing CloudKit configuration more gracefully. Check `cloudKitManager.isAvailable` before assuming CloudKit-backed features exist.

## Register your identity key

If your product uses signed peer identities, register that public key with CloudKit so other trust layers can reason about the peer correctly.

```swift
let identity = try LoomIdentityManager.shared.currentIdentity()
await cloudKitManager.registerIdentity(
    keyID: identity.keyID,
    publicKey: identity.publicKey
)
```

That is especially useful when you want share-participant trust to be bound to a specific identity key instead of only to a CloudKit account.

## Publish a peer record

Hosts typically publish their app-owned peer record with `LoomCloudKitShareManager`.

```swift
let shareManager = LoomCloudKitShareManager(
    cloudKitManager: cloudKitManager,
    shareThumbnailDataProvider: { peerRecord in
        makeThumbnailData(for: peerRecord)
    }
)
await shareManager.setup()

try await shareManager.registerPeer(
    deviceID: deviceID,
    name: serviceName,
    advertisement: advertisement,
    identityPublicKey: identity.publicKey,
    remoteAccessEnabled: remoteAccessEnabled,
    bootstrapMetadata: bootstrapMetadata
)
```

Notice what gets stored:

- the serialized ``LoomPeerAdvertisement``
- the public identity key
- whether remote access is enabled
- optional ``LoomBootstrapMetadata``

That pattern matters because it keeps the peer directory aligned with the same identity and reachability data your runtime is already using.

`registerPeer` also retries with reduced field sets when CloudKit rejects undeployed optional schema, so apps can publish base peer records while production schema catches up.

## Refresh and reuse shares

If your app already created a share for the current peer record, `createShare()` refreshes that existing share before reuse instead of creating an unrelated duplicate.

```swift
await shareManager.refresh()

let share = try await shareManager.createShare()
```

That is also where the optional `shareThumbnailDataProvider` hook applies app-owned presentation metadata without moving share lifecycle ownership out of `LoomCloudKit`.

## Fetch your own and shared peers

On the browsing side, use `LoomCloudKitPeerProvider` to fetch both private and shared records for app-owned UI.

```swift
let peerProvider = LoomCloudKitPeerProvider(cloudKitManager: cloudKitManager)
await peerProvider.fetchPeers()

let visiblePeers = peerProvider.ownPeers + peerProvider.sharedPeers
```

Each `LoomCloudKitPeerInfo` includes the decoded advertisement plus remote and bootstrap hints, which makes it a good model for a device picker or "available remotely" UI.

## Layer CloudKit into trust, not instead of trust

If you want same-account and shared-peer auto-trust, attach a `LoomCloudKitTrustProvider` to your node or higher-level service:

```swift
let trustProvider = LoomCloudKitTrustProvider(
    cloudKitManager: cloudKitManager,
    localTrustStore: LoomTrustStore()
)

node.trustProvider = trustProvider
```

This is the same shape `MirageKit` uses conceptually: CloudKit becomes another trust input, while local trust persistence and product-owned approval still exist for cases CloudKit cannot resolve.

## Keep CloudKit naming app-owned

Even though `LoomCloudKit` provides defaults, record naming is still product policy.

Use `LoomCloudKitConfiguration` to own:

- container identifier
- record types
- zone name
- participant identity record type
- device ID storage key
- share title

That keeps Loom reusable across apps with different schema and naming requirements.
