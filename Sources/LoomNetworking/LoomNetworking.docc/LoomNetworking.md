# ``LoomNetworking``

Backend-independent network values shared by Loom transports.

## Overview

Use LoomNetworking for endpoint, interface, path, service-class, and direct
connection policy values that must cross a platform-backend boundary without
exposing one operating system's socket or networking framework types.

LoomNetworking does not open sockets or select product policy. A concrete Loom
transport backend maps these values to its platform primitives while retaining
endpoint scope, interface identity, and unknown future value spellings.

## Topics

### Endpoints and routes

- ``LoomNetworkHost``
- ``LoomNetworkEndpoint``
- ``LoomNetworkInterface``
- ``LoomNetworkInterfaceType``
- ``LoomNetworkPath``
- ``LoomNetworkPathStatus``
- ``LoomNetworkServiceClass``

### Direct connection policy

- ``LoomTransportKind``
- ``LoomDirectPathKind``
- ``LoomDirectConnectionPolicy``
