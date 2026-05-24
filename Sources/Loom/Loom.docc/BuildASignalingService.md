# Build a Signaling Service

Deploy and integrate a lightweight signaling backend so peers on different networks can exchange candidates and establish direct Loom connections through NAT.

## Overview

Remote signaling is the coordination layer between two peers that cannot discover each other via Bonjour. A small HTTP service stores session state, relays connectivity candidates between host and client, and mediates the hole-punch timing that makes direct datagram connections possible.

Loom provides ``LoomRemoteSignalingClient`` for the Swift side. This article documents the signaling HTTP API so you can deploy the reference Cloudflare Worker implementation, build a compatible backend in another stack, or implement non-Swift clients.

The architecture has three cooperating pieces:

1. **Signaling service** — stores session state and mediates candidate exchange
2. **Host** — advertises presence, publishes STUN-mapped candidates, polls for clients, and hole-punches
3. **Client** — joins a session, publishes its own candidates, hole-punches the host, and initiates the direct connection

Datagram transports share one critical invariant: the client must use the **same local UDP port** for STUN, hole-punch, and the Loom connection so the NAT binding stays valid across the entire flow.

## Configure the Swift client

Create a ``LoomRemoteSignalingClient`` with your service's endpoint and credentials:

```swift
let configuration = LoomRemoteSignalingConfiguration(
    baseURL: URL(string: "https://your-worker.workers.dev")!,
    requestTimeout: 5,
    appAuthentication: LoomRemoteSignalingAppAuthentication(
        appID: "com.example.app",
        sharedSecret: "your-shared-secret"
    ),
    headerPrefix: "x-myapp"
)

let signalingClient = LoomRemoteSignalingClient(
    configuration: configuration,
    identityManager: LoomIdentityManager.shared
)
```

The `headerPrefix` determines the HTTP header names. A prefix of `x-myapp` produces headers like `x-myapp-session-id`, `x-myapp-key-id`, and so on. Your signaling backend reads these same headers.

## Host flow

The host advertises a session, polls for newly joined clients, and hole-punches their candidates:

```swift
// 1. Advertise the session (creates or heartbeats)
let result = try await signalingClient.advertisePeerSession(
    sessionID: sessionID,
    peerID: deviceID,
    acceptingConnections: true,
    peerCandidates: candidates,
    ttlSeconds: 360
)

// 2. Hole-punch any client candidates returned by the heartbeat
if !result.clientCandidates.isEmpty {
    await LoomHolePunch.punchAll(
        from: quicListenerPort,
        candidates: result.clientCandidates
    )
}

// 3. Between heartbeats, fast-poll for newly joined clients
let clientCandidates = try await signalingClient.checkForClient(
    sessionID: sessionID
)
if !clientCandidates.isEmpty {
    await LoomHolePunch.punchAll(
        from: quicListenerPort,
        candidates: clientCandidates
    )
}
```

The ``LoomRemoteSignalingClient/checkForClient(sessionID:)`` endpoint is a read-only check that costs a single Durable Object storage read with no writes, so it can be called frequently between heartbeats without meaningful cost.

## Client flow

The client picks a fixed local port, probes STUN, joins the session, hole-punches, and connects — all from the same port:

```swift
// 1. Pick a fixed local port for the entire flow
let localPort = UInt16.random(in: 49152...65535)

// 2. STUN probe from that port
let stun = await LoomSTUNProbe.run(localPort: localPort)
guard stun.reachable,
      let address = stun.mappedAddress,
      let mappedPort = stun.mappedPort else {
    return
}

// 3. Join with our candidate
try await signalingClient.joinSession(
    sessionID: sessionID,
    clientCandidates: [
        LoomRemoteCandidate(transport: .quic, address: address, port: mappedPort)
    ]
)

// 4. Fetch host candidates and hole-punch from our port
let presence = try await signalingClient.fetchPresence(sessionID: sessionID)
await LoomHolePunch.punchAll(
    from: localPort,
    candidates: presence.peerCandidates
)

// 5. Connect via the coordinator (binds datagram transports to the same port)
let session = try await coordinator.connect(
    hello: hello,
    signalingSessionID: sessionID,
    requiredLocalPort: localPort
)
```

Using the same port for all three steps is what makes NAT traversal work. ``LoomSTUNProbe/run(host:port:localPort:timeout:)`` binds the probe to a specific port. ``LoomHolePunch/punchAll(from:candidates:count:)`` sends hole-punch packets from that port. ``LoomConnectionCoordinator/connect(hello:localPeer:overlayPeer:signalingSessionID:requiredLocalPort:)`` binds datagram connection attempts to that port through the OS 26 Network parameter builders.

## Signaling HTTP API

All endpoints live under `/v1/session/` and use JSON. Every request requires dual-layer authentication described in <doc:BuildASignalingService#Authentication>.

### Candidates

Candidates describe how a peer can be reached directly:

```json
{
    "transport": "quic",
    "address": "203.0.113.10",
    "port": 4433
}
```

`transport` is `"tcp"`, `"udp"`, or `"quic"`. `address` is an IPv4 or IPv6 string. `port` is an integer from 1 to 65535. Each side can publish up to 8 candidates.

### POST /v1/session/create

Creates a new session. Called by the host.

```json
// Request
{
    "hostID": "uuid-string",
    "ttlSeconds": 360,
    "remoteEnabled": true,
    "hostCandidates": [{ "transport": "quic", "address": "203.0.113.10", "port": 4433 }]
}

// Response 200
{
    "ok": true,
    "sessionID": "uuid-string",
    "expiresAtMs": 1711234567890
}
```

Returns `409 session_exists` if a session with that ID already exists.

### POST /v1/session/heartbeat

Refreshes liveness, updates candidates, and returns client candidates for hole-punching. Called periodically by the host.

```json
// Request
{
    "role": "host",
    "remoteEnabled": true,
    "hostCandidates": [{ "transport": "quic", "address": "203.0.113.10", "port": 4433 }],
    "ttlSeconds": 360
}

// Response 200
{
    "ok": true,
    "expiresAtMs": 1711234567890,
    "clientCandidates": [{ "transport": "quic", "address": "198.51.100.5", "port": 52311 }]
}
```

### POST /v1/session/join

Joins an existing session and publishes client candidates. Acquires a single-client lock — only one client at a time.

```json
// Request
{
    "clientCandidates": [{ "transport": "quic", "address": "198.51.100.5", "port": 52311 }]
}

// Response 200
{
    "ok": true,
    "sessionID": "uuid-string",
    "lockedToClientKeyID": "sha256-hex",
    "expiresAtMs": 1711234567890
}
```

Returns `409 remote_disabled`, `409 no_host_candidates`, or `409 single_client_lock`.

### GET /v1/session/presence

Reads session state without modifying it. Used by clients during preflight and by ``LoomConnectionCoordinator`` to resolve host candidates.

```json
// Response 200 (session exists)
{
    "ok": true,
    "exists": true,
    "hostID": "uuid-string",
    "remoteEnabled": true,
    "hostCandidates": [{ "transport": "quic", "address": "203.0.113.10", "port": 4433 }],
    "clientCandidates": [],
    "lockedToClientKeyID": null,
    "expiresAtMs": 1711234567890,
    "lastHostSeenMs": 1711234500000,
    "lastClientSeenMs": null
}

// Response 200 (no session)
{ "ok": true, "exists": false }
```

### GET /v1/session/check-client

Lightweight host-only read. Returns whether any client candidates have been posted. Cheaper than a heartbeat — single storage read, no writes.

```json
// Response 200
{
    "ok": true,
    "hasClient": true,
    "clientCandidates": [{ "transport": "quic", "address": "198.51.100.5", "port": 52311 }]
}
```

Returns `403 check_client_requires_host` if the caller is not the session host.

### POST /v1/session/close

Host close deletes the session. Client close releases the lock and clears client candidates and client-originated events.

```json
// Request
{ "role": "host" }
// or
{ "role": "client" }

// Response 200
{ "ok": true }
```

### GET /v1/session/status

Returns session metadata. Restricted to the host or the locked client.

### POST /v1/session/signal

Publishes a signaling event (offer, answer, or candidate exchange) for the opposite role to poll.

```json
// Request
{ "role": "host", "kind": "candidate", "payload": { ... } }
```

### GET /v1/session/poll

Polls for signaling events from the opposite role. Query parameters: `role` (`host` or `client`) and `since` (event index).

## Authentication

Every request is signed with two independent layers. Both must pass.

### App authentication (HMAC-SHA256)

Proves the request comes from a known application. Build a canonical payload by sorting these fields alphabetically and joining with `\n`:

```
appID=com.example.app
bodySHA256=<hex-digest-of-body-or-dash>
method=POST
nonce=<uuid>
path=/v1/session/heartbeat
timestampMs=1711234567890
type=worker-app-auth-v1
```

Sign with `HMAC-SHA256(canonical_payload, shared_secret)` and include the result as base64 in the `{prefix}-app-signature` header.

### Identity authentication (ECDSA P-256)

Proves the request comes from a specific identity key. Build a canonical payload:

```
bodySHA256=<hex-digest-of-body-or-dash>
keyID=<sha256-hex-of-uncompressed-public-key>
method=POST
nonce=<uuid>
path=/v1/session/heartbeat
timestampMs=1711234567890
type=worker-request-v1
```

Sign with ECDSA-SHA256 using the caller's P-256 private key. The `keyID` is `SHA256(uncompressed_65_byte_public_key).hex()`. Both raw 64-byte (`R || S`) and DER-encoded signatures are accepted.

### Replay protection

Timestamps must be within 60 seconds of the server clock. Each `(keyID, nonce)` pair is rejected if reused within 180 seconds.

## Wire up the host signaling loop

A typical host runs a long-lived signaling loop that advertises presence, polls for clients between heartbeats, and hole-punches as soon as a client appears. The pattern from `MirageKit`:

```swift
func startSignalingLoop(
    signalingClient: LoomRemoteSignalingClient,
    sessionID: String,
    deviceID: UUID,
    quicPort: UInt16
) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            // Collect STUN-mapped candidates from datagram listener ports
            let candidates = await LoomDirectCandidateCollector.collect(
                configuration: node.configuration,
                listeningPorts: [.quic: quicPort]
            )

            // Advertise (heartbeat or create)
            let result = try? await signalingClient.advertisePeerSession(
                sessionID: sessionID,
                peerID: deviceID,
                acceptingConnections: true,
                peerCandidates: candidates,
                ttlSeconds: 360
            )

            // Immediately hole-punch if the heartbeat returned client candidates
            if let clientCandidates = result?.clientCandidates,
               !clientCandidates.isEmpty {
                await LoomHolePunch.punchAll(
                    from: quicPort,
                    candidates: clientCandidates
                )
            }

            // Fast-poll for clients during the heartbeat interval.
            // Run the check loop concurrently with the sleep so it
            // doesn't extend the interval.
            let interval = Double.random(in: 15...23)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(interval))
                }
                group.addTask {
                    for _ in 0..<10 {
                        guard !Task.isCancelled else { break }
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { break }
                        let clients = try? await signalingClient.checkForClient(
                            sessionID: sessionID
                        )
                        guard let clients, !clients.isEmpty else { continue }
                        await LoomHolePunch.punchAll(
                            from: quicPort,
                            candidates: clients
                        )
                        break
                    }
                }
                for await _ in group {}
            }
        }
    }
}
```

The fast-check loop fills idle time between heartbeats. Without it, the host only discovers client candidates when the next heartbeat fires, which could be 15-20 seconds after the client joins. With it, the host detects clients within ~2 seconds and hole-punches immediately.

## Wire up the client connection

The client picks a port, probes STUN, joins, hole-punches, and connects with retries. The coordinator handles the actual Loom connection:

```swift
func connectToRemoteHost(
    signalingClient: LoomRemoteSignalingClient,
    coordinator: LoomConnectionCoordinator,
    sessionID: String,
    hello: LoomSessionHelloRequest
) async throws -> LoomAuthenticatedSession {
    let localPort = UInt16.random(in: 49152...65535)

    // STUN from our chosen port
    let stun = await LoomSTUNProbe.run(localPort: localPort)
    var clientCandidates: [LoomRemoteCandidate] = []
    if stun.reachable, let address = stun.mappedAddress, let port = stun.mappedPort {
        clientCandidates.append(
            LoomRemoteCandidate(transport: .quic, address: address, port: port)
        )
    }

    // Join and publish our candidate
    try await signalingClient.joinSession(
        sessionID: sessionID,
        clientCandidates: clientCandidates
    )

    // Hole-punch from our port to the host's candidates
    let presence = try await signalingClient.fetchPresence(sessionID: sessionID)
    if !presence.peerCandidates.isEmpty {
        await LoomHolePunch.punchAll(
            from: localPort,
            candidates: presence.peerCandidates
        )
        try? await Task.sleep(for: .milliseconds(200))
    }

    // Retry loop — re-punch between attempts to give the host time
    // to detect our candidates and punch back
    var lastError: Error?
    for attempt in 1...3 {
        do {
            return try await coordinator.connect(
                hello: hello,
                signalingSessionID: sessionID,
                requiredLocalPort: localPort
            )
        } catch {
            lastError = error
            if attempt < 3 {
                let refreshed = try? await signalingClient.fetchPresence(
                    sessionID: sessionID
                )
                if let hosts = refreshed?.peerCandidates, !hosts.isEmpty {
                    await LoomHolePunch.punchAll(
                        from: localPort,
                        candidates: hosts
                    )
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    throw lastError!
}
```

The retry loop is important. NAT hole-punching is a race: the host and client need to punch each other's NAT before the datagram handshake. If the first attempt misses the timing window, re-punching and retrying after a few seconds usually succeeds because the host's fast-check loop has had time to find the client's candidates and punch back.

## Build and deploy your own signaling service

Loom defines the signaling protocol but does not ship a backend. You need to deploy your own service that implements the endpoints and authentication described above. The service is simple — it stores session state, validates signatures, and returns JSON. Any HTTP backend with a small amount of persistent storage works.

### Choose an infrastructure approach

The service needs two things: an HTTP endpoint and per-session storage that survives across requests. Common options:

| Approach | Storage | Notes |
|----------|---------|-------|
| Cloudflare Worker + Durable Object | DO storage | Lowest latency, session state colocated per-DO, auto-expiry via alarms |
| AWS Lambda + DynamoDB | DynamoDB TTL | Serverless, TTL attribute handles expiry |
| A small server (Hummingbird, Vapor, Express) | SQLite or Redis | Simple to debug, good for dev/staging |

The Cloudflare Durable Object approach is a natural fit because each session maps to one DO instance, so all reads and writes for a session are local with no coordination.

### Implement the session lifecycle

A minimal implementation needs to handle four operations:

1. **Create** — Store a new session with host identity, candidates, TTL, and expiry timestamp.
2. **Heartbeat** — Update the session's TTL, candidates, and `lastHostSeenMs`. Return any stored `clientCandidates`.
3. **Join** — Validate the session exists and is accepting connections. Store the client's identity and candidates. Enforce a single-client lock.
4. **Presence** — Return the session state without modifying it.

Add `check-client` (read-only client candidate check) and `close` (delete session or release client lock) for a complete implementation. The `signal` and `poll` endpoints are only needed if you plan to exchange out-of-band messages between host and client beyond candidate exchange.

### Implement authentication

Every request carries two independent signature layers. Both must pass before the endpoint logic runs.

**App authentication** prevents unauthorized clients from touching your signaling service. You pick an app ID and shared secret. The canonical payload is built by sorting these fields alphabetically and joining with newlines:

```
appID=com.example.app
bodySHA256=<sha256-hex-of-body-or-"-">
method=POST
nonce=<uuid>
path=/v1/session/heartbeat
timestampMs=1711234567890
type=worker-app-auth-v1
```

Verify by computing `HMAC-SHA256(canonical_bytes, shared_secret)` and comparing to the base64 value in the `{prefix}-app-signature` header.

**Identity authentication** binds each request to a specific P-256 key pair. The canonical payload:

```
bodySHA256=<sha256-hex-of-body-or-"-">
keyID=<sha256-hex-of-65-byte-uncompressed-public-key>
method=POST
nonce=<uuid>
path=/v1/session/heartbeat
timestampMs=1711234567890
type=worker-request-v1
```

Verify the ECDSA-P256-SHA256 signature from the `{prefix}-signature` header against the public key from `{prefix}-public-key`. Accept both raw 64-byte and DER-encoded signatures — Swift's CryptoKit produces DER by default.

The `keyID` is `SHA256(public_key_bytes).hex()` where `public_key_bytes` is the 65-byte uncompressed form (`04 || X || Y`). Verify that the provided `{prefix}-key-id` header matches the derived value.

**Replay protection**: reject timestamps more than 60 seconds from the server clock. Record each `(keyID, nonce)` pair and reject duplicates within 180 seconds.

### Implement session expiry

Sessions should auto-expire when the TTL elapses without a heartbeat renewal. The TTL is host-controlled, clamped between 30 and 900 seconds, defaulting to 360.

On Cloudflare, use `storage.setAlarm(expiresAtMs)` to schedule cleanup. On DynamoDB, use a TTL attribute. On a server, run a periodic sweep or check expiry on each read.

### Example: Cloudflare Worker skeleton

```typescript
export class SignalingSessionDO {
    constructor(private state: DurableObjectState, private env: Env) {}

    async fetch(request: Request): Promise<Response> {
        // 1. Verify app auth (HMAC-SHA256)
        // 2. Verify identity auth (ECDSA P-256)
        // 3. Check replay (timestamp window + nonce dedup)
        // 4. Read session from storage
        // 5. Route to endpoint handler
        // 6. Write updated session, return JSON
    }

    async alarm() {
        // Delete expired session
        const session = await this.state.storage.get("session");
        if (session && Date.now() >= session.expiresAtMs) {
            await this.state.storage.delete("session");
        }
    }
}
```

The Worker entry point routes by `x-{prefix}-session-id` header to the appropriate Durable Object instance:

```typescript
export default {
    async fetch(request: Request, env: Env) {
        const sessionID = request.headers.get("x-myapp-session-id");
        if (!sessionID) return new Response("missing session id", { status: 400 });
        const id = env.SIGNALING_SESSIONS.idFromName(sessionID);
        return env.SIGNALING_SESSIONS.get(id).fetch(request);
    }
};
```

### Validate your implementation

The Swift client does not assume any particular backend. As long as your service returns the correct JSON shapes and validates both auth layers, ``LoomRemoteSignalingClient`` works out of the box. Test by:

1. Configuring ``LoomRemoteSignalingConfiguration`` with your deployed URL, app ID, and shared secret.
2. Calling ``LoomRemoteSignalingClient/advertisePeerSession(sessionID:peerID:acceptingConnections:peerCandidates:advertisement:ttlSeconds:)`` from a host and verifying a `200` response.
3. Calling ``LoomRemoteSignalingClient/fetchPresence(sessionID:)`` from a client and verifying the host's candidates appear.
4. Calling ``LoomRemoteSignalingClient/joinSession(sessionID:clientCandidates:)`` and checking that the next heartbeat returns the client's candidates.
