# fanout

**File:** `src/worker/control/fanout.zig`  
**Module:** `worker/control`  
**Description:** Streams a running swarm's `events.jsonl` to watchers — a byte-cursor poll and a live SSE stream — so the desktop, the web UI, and `veil events` all see a cast round-by-round.

---

## Purpose Summary

`control/fanout.zig` is the read side of a live cast. A worker appends narration to its run-dir `events.jsonl` as it works; this module serves that log two ways: a positional cursor poll (`?from=N`, whole-file length returned via `X-Next-Offset`) and a continuous stream. Reading positionally from the client's cursor keeps one response bounded even for a long-running swarm whose log grows without bound — the client catches up across polls by advancing its offset.

## Key surfaces

- `swarmEvents` — `GET /api/v1/swarms/:id/events?from=N` — the cursor poll. The chat side's `convEvents` (`chat/service.zig`) is a verbatim twin of this over the conversation's `events.jsonl`.
- `swarmStream` — `GET /api/v1/swarms/:id/stream` — the live SSE stream.

## Dependencies

- `worker/control/supervisor` — resolves the swarm id to its run directory
- `gateway/http` — response helpers and content types

## Usage Context

The event surface every watcher reads: `veil events <id> [--follow]` tails the cursor poll; the desktop poller and the web control plane consume the same routes. The chat brain reuses the identical cursor protocol for its own turn events.

---

*Documentation generated for nl-veil — worker/control/fanout.zig source analysis.*
