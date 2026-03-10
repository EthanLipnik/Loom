# Query Peers, Connections, and Transfers

``LoomQuery`` is the SwiftUI-facing read model for LoomKit.

Use it the same way you would use SwiftData's `@Query`: ask for the slice of runtime state a view needs, then let the shared context publish updates as the runtime changes.

## Query The Current Context

`LoomQuery` always reads from the current environment's ``LoomContext``:

```swift
struct SidebarView: View {
    @LoomQuery(.peers(filter: .nearby, sort: .name))
    private var nearbyPeers: [LoomPeerSnapshot]

    @LoomQuery(.connections(filter: .connected))
    private var activeConnections: [LoomConnectionSnapshot]

    var body: some View {
        List {
            Section("Nearby") {
                ForEach(nearbyPeers) { peer in
                    Text(peer.name)
                }
            }

            Section("Connected") {
                ForEach(activeConnections) { connection in
                    Text(connection.peerName)
                }
            }
        }
    }
}
```

## Query Snapshots, Not Network Objects

The values returned by ``LoomQuery`` are snapshots:

- ``LoomPeerSnapshot`` merges nearby discovery, CloudKit visibility, and relay reachability by logical device identifier.
- ``LoomConnectionSnapshot`` is a UI-friendly projection of a connection's lifecycle and transport kind.
- ``LoomTransferSnapshot`` tracks progress without forcing the view layer to subscribe directly to transfer streams.

That separation is intentional. SwiftUI gets deterministic value updates, while the transport and streaming work stays inside the shared runtime and the per-connection handles.

## Pick Narrow Filters

Use filters to keep each view honest about what it needs:

- ``LoomPeerFilter/nearby`` for local peer pickers.
- ``LoomPeerFilter/remoteAccessEnabled`` for remote-join UI.
- ``LoomConnectionFilter/connected`` for active session chrome.
- ``LoomTransferFilter/active`` for a live transfer HUD.

If a view needs richer behavior than a snapshot can provide, resolve the selected row back into a ``LoomConnectionHandle`` through ``LoomContext`` rather than teaching the query layer about transport callbacks.

## Querying Is Cheap; Connecting Is Not

Treat queries as read-only and side-effect free. Trigger actual work through ``LoomContext`` actions such as ``LoomContext/start()``, ``LoomContext/refreshPeers()``, and ``LoomContext/connect(_:)``.

For a full walkthrough, see <doc:BuildASwiftUIAppWithLoomKit>.
