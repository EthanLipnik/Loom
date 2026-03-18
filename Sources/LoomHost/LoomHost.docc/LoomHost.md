# ``LoomHost``

`LoomHost` is the macOS-only shared-host runtime for Loom-based apps that participate in one App Group.

## Overview

Use `LoomHost` when multiple apps on the same Mac should share one Loom network owner instead of each app independently advertising, publishing signaling presence, and opening authenticated sessions.

The package keeps the architectural boundary explicit:

- `LoomHost` owns App Group coordination, Unix-socket IPC, leader election, and host-scoped session virtualization.
- `Loom` continues to own discovery, identity, trust, transport, and signaling primitives.
- `LoomKit` remains the app-facing container/context layer and can opt into shared hosting without changing its own public interaction model.

Shared-host mode is intentionally scoped:

- macOS only
- one developer-controlled App Group
- one host identity and trust boundary per shared runtime

Remote peers still look app-shaped. `LoomHost` publishes one host advertisement with a Loom-owned host catalog, and Loom consumers expand that catalog into app-specific peers during discovery.

## Topics

### Essentials

- <doc:LoomHostTutorials>
- ``LoomSharedHostConfiguration``
- ``LoomHostAppDescriptor``

### Runtime Coordination

- ``LoomHostClient``
- ``LoomHostBroker``
