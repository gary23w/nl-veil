# evcursor

**File:** `src/worker/evcursor.zig`  
**Module:** `worker`  
**Description:** The byte-cursor contract shared by the two events.jsonl poll endpoints — the size-probe sentinel, the page cap, and the offset arithmetic that one piece of client code depends on.

---

## Purpose Summary

Two endpoints serve events.jsonl by byte cursor: `control/fanout.zig` swarmEvents for a swarm's run
dir and `chat/service.zig` convEvents for a conversation's dir. The web console polls both with the
same client code, so any behavioral difference between them is a bug. The contract used to be
duplicated in both handlers under a "change one, change the other" comment; it lives here now, which
makes the lockstep structural and the arithmetic testable away from the HTTP layer.

## Key Exports

- `PROBE` — the sentinel `from` value (max u64) requesting a size probe instead of a body
- `PAGE_MAX` — 512 KiB, the most one poll may return; deliberately under the client's 1 MB
  per-response cap
- `parseFrom(raw)` — the `from`/`offset` query value; missing, junk, negative, and overflowing
  values all degrade to 0 rather than an error the client must handle
- `isProbe(from)` — is this poll a size probe
- `want(size, from)` — how many bytes to read at `from`, capped at `PAGE_MAX`; 0 means nothing to
  send
- `nextOffset(from, n)` — the cursor to hand back after actually reading `n` bytes

## Dependencies

- `std` only — no io, no allocator, no HTTP types; that is what makes it directly testable.

## Usage Context

Imported by `worker/control/fanout.zig` (swarmEvents) and `worker/chat/service.zig` (convEvents).
The SSE stream in fanout.zig faces the same file but keeps its own loop-local cursor.

## Notable Implementation Details

A capped whole-file read is the bug this exists to prevent: once events.jsonl crossed the cap every
poll returned EMPTY, which reset the client's cursor to 0 and replayed history as live events. The
file only grows, so a positional read from `from` stays valid and one poll's payload stays bounded.

`want` returns 0 when `size <= from`, so a shrunken (truncated or rotated) file leaves a polling
client parked past EOF — events.jsonl only grows today, and the SSE loop facing the same file
rewinds instead. A test pins that asymmetry so it stays a decision rather than an accident.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
