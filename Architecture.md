# Loom Architecture

This document describes the generic networking package in `Loom/`.

It applies to:

- `Sources/Loom`
- `Sources/LoomCloudKit`
- `Tests/LoomTests`
- `Tests/LoomCloudKitTests`

## 1. Package Topology

Loom is a standalone Swift package with two products:

- `Loom`
- `LoomCloudKit`

Supported platforms:

- macOS 14+
- iOS 17.4+
- visionOS 26+

External dependencies:

- `swift-nio`
- `swift-nio-ssh`

## 2. Ownership Boundary

Loom is intentionally product-agnostic.

It owns:

- peer discovery
- transport and session lifecycle
- authenticated-session bootstrap phase reporting
- signaling/direct connectivity
- identity and trust
- replay protection
- diagnostics and instrumentation
- bootstrap transport
- STUN and remote signaling
- CloudKit-backed discovery, sharing, and trust

It does not own product-specific:

- service types
- CloudKit record naming
- signaling header prefixes
- control message schemas
- stream, window, app, or UI semantics

## 3. Core Types

### 3.1 Node and Session

- `LoomNode` is the main entry point.
- `LoomSession` represents an established connection lifecycle.
- `LoomPeer` is the discovered or remote-resolved peer model.

`LoomNode` composes discovery, identity, trust, and transport policy into a single object higher-level packages can own directly.

### 3.2 Identity and Trust

- `LoomIdentityManager` manages signing keys and shared-key derivation.
- `LoomTrustProvider` abstracts approval policy.
- `LoomTrustStore` provides local persistence for trusted peers.
- `LoomCloudKitTrustProvider` adds CloudKit-backed trust semantics when needed.

### 3.3 Remote and Bootstrap

- `LoomRelayClient` handles signaling-backed remote coordination.
- `LoomSTUNProbe` discovers external candidate information.
- `LoomBootstrapEndpointResolver`, `LoomBootstrapControlClient`, `LoomWakeOnLANClient`, and `LoomSSHBootstrapClient` support peer recovery and bootstrap flows.

### 3.4 Diagnostics

- `LoomDiagnostics` handles structured log/error fan-out and runtime context providers.
- `LoomLogCategory` is string-backed and open so higher-level packages can define their own category vocabularies.
- `LoomInstrumentation` captures timeline-style lifecycle events.

These sinks are generic and reusable. Higher-level packages add their own categories and context without changing Loom’s ownership model.

### 3.5 UDP Session Transport

`LoomReliableChannel` defines the authenticated-session UDP transport contract:

- reliable control messages and unreliable datagrams may share a single UDP connection
- reliable packets use selective acknowledgements, retransmission, and fragment reassembly
- the receiver may emit an immediate dedicated ACK after an idle gap instead of waiting for the normal coalescing window
- timeout decisions consider both retry budget and whether the peer is still actively sending traffic on the session

The transport should fail truly dead peers promptly without collapsing a still-live session just because reliable control and high-rate unreliable traffic briefly contend for receive scheduling.

## 4. Layering Rule

Packages above Loom should:

- depend on Loom types directly
- inject product defaults from the product package
- keep product protocol/schema definitions out of Loom

If a type starts carrying product-specific naming or assumptions, it belongs above Loom.
