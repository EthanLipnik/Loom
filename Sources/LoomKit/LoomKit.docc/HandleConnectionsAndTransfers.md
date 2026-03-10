# Handle Messages and Transfers

Use ``LoomConnectionHandle`` for everything that is truly connection-scoped:

- sending and receiving messages
- observing connection lifecycle events
- offering or accepting file transfers
- opening custom multiplexed streams when the default message stream is not enough

## The Default Message Stream

LoomKit reserves one lazily-created multiplexed stream for app messages. Call one of the `send` overloads to write to it:

```swift
let connection = try await loomContext.connect(peer)
try await connection.send("hello")
```

Receive from the same logical message channel by iterating ``LoomConnectionHandle/messages``:

```swift
Task {
    for await payload in connection.messages {
        // Decode or route the message in your app layer.
    }
}
```

If your app needs a separate framing boundary, open another stream explicitly with ``LoomConnectionHandle/openStream(label:)``.

## Observe Incoming Sessions At The Context Level

Incoming connections arrive through ``LoomContext/incomingConnections``:

```swift
Task {
    for await connection in loomContext.incomingConnections {
        Task {
            for await event in connection.events {
                // Update app-owned state or route protocol events.
            }
        }
    }
}
```

This is the recommended split:

- The context tells your app that a new connection exists.
- The handle owns the per-connection async streams.
- Your app decides what protocol, approval flow, or domain model sits above those streams.

## Use The Transfer Engine Through The Handle

LoomKit exposes Loom's transfer engine through convenience methods on the handle:

```swift
let transfer = try await connection.sendFile(
    at: screenshotURL,
    named: "capture.png",
    contentType: "image/png"
)
```

Accept incoming transfers with ``LoomConnectionHandle/accept(_:to:resumeIfPossible:)`` and drive progress UI from ``LoomQuery`` over ``LoomTransferSnapshot`` values.

## Keep Domain Protocols Above LoomKit

`LoomKit` deliberately stops at transport, discovery, trust, relay reachability, and file transfer. Message schemas, approval UX, retry policy, and app semantics should remain in your app layer.

For a step-by-step walkthrough, see <doc:HandleMessagesAndTransfersWithLoomKit>.
