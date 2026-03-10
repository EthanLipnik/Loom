# Transfer Large Objects

Loom now includes a generic bulk object transfer layer on top of authenticated sessions.

The important boundary is unchanged:

- Loom owns secure session setup, direct transport selection, resumable object transfer, and diagnostics.
- Your app still owns file manifests, approval UX, multi-file grouping, previews, and product policy.

## Start from an authenticated session

Use ``LoomNode/startAuthenticatedAdvertising(serviceName:helloProvider:onSession:)`` and ``LoomNode/connect(to:using:hello:queue:)`` so both peers negotiate an encrypted authenticated session before any transfer begins.

`LoomAuthenticatedSession` now requires the `loom.session-encryption.v1` feature and encrypts post-handshake traffic automatically.

## Create a transfer engine

Build one ``LoomTransferEngine`` per authenticated session:

```swift
let transferEngine = LoomTransferEngine(session: session)
```

It exposes:

- ``LoomTransferEngine/incomingTransfers``
- ``LoomTransferEngine/offerTransfer(_:source:)``

## Offer one opaque object at a time

Use ``LoomTransferOffer`` to describe a single transferable object:

- logical name
- byte length
- optional content type
- optional SHA-256
- opaque metadata dictionary

That keeps Loom generic. If your app wants to send a folder or a set of files, model that bundle above Loom and offer one object per item or one app-defined archive object.

## Use offset-based sources and sinks

`LoomTransferSource` and `LoomTransferSink` are offset-based so Loom can resume from a contiguous prefix without buffering the entire object in memory.

Loom ships URL-backed helpers:

- ``LoomFileTransferSource``
- ``LoomFileTransferSink``

Apps can provide their own memory, database, or content-addressed implementations as long as they satisfy the same byte-range contract.

## Scheduler behavior

`LoomTransferEngine` applies ``LoomTransferConfiguration`` to outgoing transfers:

- chunked sends use the configured chunk size
- per-transfer and global in-flight windows cap concurrent bulk traffic
- the default `adaptiveHybrid` scheduler gives short transfers extra turns so UI-visible items are not stuck behind much larger objects

## Resume semantics

v1 resume is intentionally simple:

- the receiver accepts a transfer with a single contiguous resume offset
- the sender starts streaming from that offset
- sparse range repair is out of scope

That is enough for interrupted large-object transfers without turning Loom into a full sync engine.

## What stays above Loom

Keep these concerns in your app:

- approval or auto-accept policy
- album, folder, or bundle semantics
- previews and presentation metadata
- same-account or contacts-only UX
- persistence rules for partial transfers
