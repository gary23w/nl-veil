# tail_fanout

**File:** `src/orchestrate/tail_fanout.zig`  
**Module:** `orchestrate`  
**Description:** Fan-out log-streaming service: tails logs from multiple sources and distributes events to subscribers for real-time observability.

---

## Purpose Summary

Fan-out log-streaming service: tails logs from multiple sources and distributes events to subscribers for real-time observability.

## Key Exports

- `TailFanout` struct — event distributor
- `subscribe()` — register listener
- `emit()` — publish event
- `FanoutConfig` — buffer size, retry, backpressure

## Dependencies

- `orchestrate/neuron_client` — event transport
- Standard library: collections, threading, time

## Usage Context

Used by observability tooling and real-time dashboards. Can handle high-throughput log streams.

## Notable Implementation Details

Implements a sliding-window buffer for slow subscribers. Drops oldest events under backpressure rather than blocking producers.

---

*Documentation generated for nl-veil — tail_fanout.zig source analysis.*
