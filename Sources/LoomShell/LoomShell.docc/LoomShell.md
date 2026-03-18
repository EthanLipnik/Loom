# ``LoomShell``

Build terminal-class apps on top of Loom-native direct transport, signaling introduction, and optional emergency SSH recovery.

## Overview

`LoomShell` is the app-facing product for building shell and terminal apps with Loom.

Use it when you want:

- nearby shell sessions over Bonjour and AWDL
- remote shell sessions that still stay direct, with signaling used only as an introducer
- CloudKit-aware trust at the Loom session layer
- a Loom-native PTY protocol for your own host app
- emergency SSH for peers that expose an OpenSSH host-certificate endpoint

`LoomShell` sits above `Loom`:

- `Loom` owns discovery, authenticated transport, trust, signaling rendezvous, and bootstrap primitives
- `LoomShell` owns shell session protocol, host runtime wiring, connection policy, and emergency SSH recovery

On macOS, `LoomLocalShellHost` gives you a PTY-backed host runtime out of the box. On every client platform supported by Loom, `LoomShellConnector` gives you one connection API that prefers Loom-native transport first and OpenSSH second.

## Topics

### Essentials

- <doc:BuildAShellAppOnLoom>
