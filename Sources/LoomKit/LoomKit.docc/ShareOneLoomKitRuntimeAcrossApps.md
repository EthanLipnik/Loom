# Share One LoomKit Runtime Across Apps

Use this guide when multiple macOS apps in one App Group should behave like one Loom host on the network.

The key architectural point is that `LoomKit` stays the app-facing API surface. You still create one ``LoomContainer`` per process, inject ``LoomContext`` into SwiftUI, and read peers through ``LoomQuery``. The difference is that each process opts into a shared runtime through ``LoomContainerConfiguration/appGroup`` so one App Group-scoped runtime owns discovery, signaling presence, and authenticated sessions.

## When To Use It

Choose shared-host mode when:

- multiple apps from the same developer should advertise as one host device
- you want one network owner per Mac instead of one per process
- each app still needs its own app identity, metadata, and feature flags in the peer list

Do not use it when each app should maintain an independent Loom identity or trust boundary.

## What Changes In LoomKit

Set ``LoomContainerConfiguration/appGroup`` with a ``LoomAppGroupConfiguration`` value that describes:

- the App Group boundary
- the current app's stable app identifier
- the display name and metadata that should appear in the synthesized peer list

Once enabled:

- nearby discovery still produces ``LoomPeerSnapshot`` values
- remote and CloudKit state still merge into the same peer model
- ``LoomContext/connect(_:)`` and ``LoomContext/connect(remoteSessionID:)`` keep the same signatures

That is the main reason to learn this from the LoomKit side first: adopting shared-host mode should not force the SwiftUI layer to relearn the runtime.

## Learn The Setup

- Start with <doc:ShareOneLoomKitRuntimeAcrossMacOSApps> for the step-by-step LoomKit setup.
- Read <doc:EnableCloudPeersAndRemoteAccess> if the same app also needs CloudKit sharing or signaling-backed joins.
