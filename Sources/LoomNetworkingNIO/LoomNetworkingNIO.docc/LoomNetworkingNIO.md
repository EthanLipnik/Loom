# ``LoomNetworkingNIO``

Open portable TCP and UDP connections through Loom's backend-independent network contracts.

## Overview

`LoomNetworkingNIO` maps `LoomNetworkEndpoint` values and
connection options to SwiftNIO sockets. Use ``LoomNIONetworkBackend`` when a
runtime needs direct stream and datagram transport without Network.framework.

DNS-SD discovery, protected identity storage, authenticated sessions, and
product retry policy remain separate concerns. The backend rejects unsupported
interface binding and QUIC requests explicitly instead of silently changing
their meaning.

## Topics

### Direct transport

- ``LoomNIONetworkBackend``
