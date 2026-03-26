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

If your product publishes peer identity in CloudKit and also sends a device ID during handshakes, keep those paths on the same stable device ID. When migrating from older per-target defaults keys, move them into your shared device-ID slot before CloudKit initialization so the published identity record keeps lining up with the runtime handshake identity.

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

## Set up and deploy your CloudKit schema

Before any of the above code works, your CloudKit container needs the right record types, fields, and indexes. The Development environment auto-creates schema when your app writes records for the first time, but Production does not — you must deploy explicitly.

### 1. Enable CloudKit on your App ID

1. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list).
2. Select your App ID, enable **iCloud**, and check **CloudKit**.
3. Create or select a container (e.g. `iCloud.com.yourcompany.YourApp`).

### 2. Create record types in the Development environment

Open the [CloudKit Console](https://icloud.developer.apple.com/), select your container, and make sure the **Environment** toggle is set to **Development**.

Create these record types with the fields listed below. If you customized the names via ``LoomCloudKitConfiguration``, use your custom names instead of the defaults.

**LoomDevice** (or your custom `deviceRecordType`):

| Field | Type |
|---|---|
| `name` | String |
| `deviceType` | String |
| `lastSeen` | Date/Time |
| `identityKeyID` | String |
| `identityPublicKey` | Bytes |

**LoomPeer** (or your custom `peerRecordType`):

| Field | Type |
|---|---|
| `deviceID` | String |
| `name` | String |
| `createdAt` | Date/Time |
| `lastSeen` | Date/Time |
| `deviceType` | String |
| `advertisementBlob` | Bytes |
| `identityPublicKey` | Bytes |
| `remoteAccessEnabled` | Int(64) |
| `relaySessionID` | String |
| `bootstrapMetadataBlob` | Bytes |

**LoomParticipantIdentity** (or your custom `participantIdentityRecordType`):

| Field | Type |
|---|---|
| `keyID` | String |
| `publicKey` | Bytes |
| `lastSeen` | Date/Time |

> Tip: You can skip the record-type creation step in the Console. Run your app in a debug build against the Development environment first and Loom will auto-create the schema by writing records. The `LoomCloudKitShareManager` retries with progressively fewer fields when the schema rejects undeployed columns, so even a partial schema works during development.

### 3. Add indexes

Still in the Development environment, open each record type and add indexes. At minimum:

- **LoomDevice**: `recordName` (Queryable), `name` (Queryable)
- **LoomPeer**: `recordName` (Queryable), `deviceID` (Queryable, Searchable)
- **LoomParticipantIdentity**: `recordName` (Queryable), `keyID` (Queryable, Searchable)

CloudKit requires at least one Queryable index per record type to support `CKQuery` operations.

### 4. Deploy schema to Production

Once you have verified everything works in Development:

1. In the CloudKit Console, go to **Schema** in the left sidebar.
2. Click **Deploy Schema to Production…** (or **Deploy Schema Changes…** depending on Console version) in the upper area of the schema page.
3. Review the diff of record types, fields, and indexes that will be deployed.
4. Confirm the deployment.

> Important: Production schema is additive. You can add new record types and fields, but you cannot remove or rename fields that have already been deployed. Plan your field names carefully before deploying for the first time.

### 5. Verify

Switch the Environment toggle to **Production** and confirm your record types, fields, and indexes are all present. Your App Store and TestFlight builds use the Production environment automatically — only Xcode debug builds hit Development.
