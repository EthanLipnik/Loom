# Adopt LoomKit in SwiftUI

Use `LoomKit` when you want Loom's nearby discovery, authenticated sessions, transfer engine, optional CloudKit peer sharing, and optional relay reachability to show up in SwiftUI as one coherent runtime.

`LoomKit` is intentionally modeled after SwiftData:

- ``LoomContainer`` is the shared runtime owner, similar to `ModelContainer`.
- ``LoomContext`` is the main-actor action surface you inject into views, similar to a model context.
- ``LoomQuery`` projects live runtime snapshots into SwiftUI lists without making each view own networking tasks.
- ``LoomConnectionHandle`` is the escape hatch for long-lived async work such as receiving messages or accepting file transfers.

## Start With One Container

Create one ``LoomContainer`` for your app or scene and attach it with the `.loomContainer(_:autostart:)` modifiers on your SwiftUI `View` or `Scene`.

```swift
import LoomKit
import SwiftUI

@main
struct ExampleApp: App {
    let loomContainer = try! LoomContainer(
        for: .init(
            serviceType: "_example._tcp",
            serviceName: "Example Mac",
            deviceIDSuiteName: "group.com.example.shared"
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .loomContainer(loomContainer)
    }
}
```

With `autostart` left at its default value of `true`, LoomKit starts the shared runtime when the scene appears and stops it when the scene goes away.

## Read Snapshots In Views

Inside SwiftUI views, use `@Environment(\\.loomContext)` for actions and ``LoomQuery`` for read-only snapshot state:

```swift
struct ContentView: View {
    @Environment(\.loomContext) private var loomContext
    @LoomQuery(.peers(sort: .name)) private var peers: [LoomPeerSnapshot]

    var body: some View {
        List(peers) { peer in
            Button(peer.name) {
                Task {
                    _ = try await loomContext.connect(peer)
                }
            }
        }
    }
}
```

`LoomQuery` is intentionally passive. It filters and sorts state already projected into the context. It does not spin up discovery observers or transport tasks from the view layer.

## Keep Live I/O In Handles

When the app connects to a peer or accepts an incoming session, LoomKit returns a ``LoomConnectionHandle``. That actor owns the long-lived `AsyncStream` values for messages, connection events, and incoming transfers.

This keeps the concurrency split clean:

- Views render snapshots.
- The context starts, stops, refreshes, and connects.
- Handles own per-connection async work.

## Next Steps

- Follow <doc:BuildASwiftUIAppWithLoomKit> for the quickest end-to-end integration.
- Read <doc:QueryPeersConnectionsAndTransfers> to understand how `@LoomQuery` behaves.
- Read <doc:HandleConnectionsAndTransfers> before you build message or transfer features.
