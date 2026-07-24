# writer

**File:** `src/worker/control/writer.zig`  
**Module:** `worker/control`  
**Description:** The swarm control bus writer: turns a `POST /api/v1/swarms/:id/control` request into a cooperative op on the running swarm — stop, steer (say), or set a new goal — that the worker reads between rounds.

---

## Purpose Summary

`control/writer.zig` is how the outside world steers a live hive without killing it. It writes control ops to the swarm's run-dir control bus; the running worker drains them between rounds and folds them in. Ops are cooperative — a `stop` asks the swarm to wind down, a `say` injects a directive for the next round, a `set_goal` rewrites the objective.

## Key surfaces

- `swarmControl` — the `POST /api/v1/swarms/:id/control` handler. Body is `{"op":…, "text":…}`: `stop`, `say`, `set_goal`.
- Structural ownership: the swarm id resolves under the caller's own registry entry, so a caller can only steer its own swarms.

## Dependencies

- `worker/control/supervisor` — resolves the swarm id to its run directory
- `gateway/http` — request/response helpers

## Usage Context

Behind `veil stop <id>` (`{"op":"stop"}`), `veil hub all "<text>"` (broadcast `say` to every swarm), and `veil hub goal "<text>"` (`set_goal`). The desktop's steer controls write the same bus. The chat brain uses a separate per-conversation `control.jsonl` (see `chat/service.zig`); this writer is the swarm-side equivalent.

---

*Case file grounded in the module's `//!` header and public API.*
