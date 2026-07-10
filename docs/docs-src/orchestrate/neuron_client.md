# neuron_client

**File:** `src/orchestrate/neuron_client.zig`  
**Module:** `orchestrate`  
**Description:** Client library for inter-neuron communication — message passing, remote procedure calls, and event subscription across agent nodes.

---

## Purpose Summary

Client library for inter-neuron communication — message passing, remote procedure calls, and event subscription across agent nodes.

## Key Exports

- `NeuronClient` struct — comms client
- `send()` — send message to neuron
- `subscribe()` — subscribe to neuron events
- `rpc()` — remote procedure call with timeout

## Dependencies

- Standard library: networking, serialization (JSON/MessagePack)
- `config/key_vault` — optional TLS mutual auth

## Usage Context

Used by all orchestration modules for internode communication. Created at startup with cluster configuration.

## Notable Implementation Details

Connections are multiplexed over a single TCP/TLS socket using a custom framing protocol. Supports request/response and pub/sub patterns.

---

*Documentation generated for nl-veil — neuron_client.zig source analysis.*
