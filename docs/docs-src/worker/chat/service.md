# service

**File:** `src/worker/chat/service.zig`  
**Module:** `worker/chat`  
**Description:** The chat REST handlers — the per-conversation surface a thin client (veil-desk, `veil chat`) drives. It lists, reads, and deletes conversations, streams a running turn's event frames, accepts a new message, and carries cooperative control ops (stop / steer) to the running turn.

---

## Purpose Summary

`service.zig` is the server-side conversation store's HTTP surface. A conversation `{conv}` lives at `{data}/u{uid}/_chat/convs/{safeSeg(conv)}/` with `messages.jsonl` (the durable turn log), `events.jsonl` (live turn narration), and `control.jsonl` (client control ops). Ownership is structural: every path is built from the authenticated user's own `uid`, so a caller can only reach its own conversations — the per-uid prefix IS the ownership check.

The read handlers degrade gracefully: a missing convs root → empty list, a missing conv dir → `404`, a missing `messages.jsonl` / `events.jsonl` → empty body.

## Routes

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/chat/convs` | list this user's conversations → `{ok, convs:[{id,title,updated,msgs}]}` |
| `GET` | `/api/v1/chat/convs/:id` | the full message log → `{ok, id, messages:[…]}` (404 if absent) |
| `DELETE` | `/api/v1/chat/convs/:id` | remove one conversation's whole tree (404 if absent) |
| `GET` | `/api/v1/chat/convs/:id/events?from=N` | byte-cursor poll of `events.jsonl`; whole-file length back via `X-Next-Offset` |
| `POST` | `/api/v1/chat/convs/:id/messages` | run ONE server-side agentic turn (see below) |
| `POST` | `/api/v1/chat/convs/:id/control` | append a control op — `{"op":"stop"}` or `{"op":"steer","text":…}` |

## The message route

`postMessage` is the write door into `chat/engine.zig`. Notable behaviour:

- **Kill switch first.** `VEIL_CHAT_BACKEND=0` returns `501` before auth or parsing, so a disabled backend degrades cleanly to a client's local fallback rather than erroring.
- **Open to every authenticated user, gated per role.** `postMessage` is not admin-restricted. The dangerous half of the tool surface (code-exec / host / engine self-mod) is withheld by capability instead: a non-admin turn runs `.sandboxed`, and `tools.execute` refuses anything outside the sandbox allowlist before the tool runs, confining that user to their own `u{uid}` workspace. Admins run `.full`. Tool DELEGATION (`tool_client` on the body) is admin-only as well — delegating hands tools to a client harness instead of `tools.execute`, which would otherwise route around that gate.
- **Body.** `{text, base_url, model, api_key, loop}` — `loop` selects the auto-loop tier (`0` off, `1` on, `2` afk); garbage degrades to `0` (never the most-expensive tier).
- **One turn per conversation.** `tryBeginTurn` claims the per-conv slot; a racing request gets `409`. On success the handler fires the turn on a background thread and returns `202` at once with an `events_url`, so the client streams frames live via `/events` instead of blocking on the whole (possibly multi-step) turn.

The `/events` poll reads *positionally* from the client's `from` cursor rather than the whole file, so a long persistent (afk) turn that appends indefinitely never overruns a fixed read cap; the client advances its cursor across polls.

## Dependencies

- `gateway/http` — `App`, `requireUser`, `badReq`, `notFound`, JSON helpers
- `worker/chat/engine` — `tryBeginTurn` + `spawnTurn` (the turn loop this surface fronts)

## Usage Context

The exact surface veil-desk and the `veil chat` CLI both drive: POST a message, stream the turn's frames from `/events`, steer or stop the running turn via `/control`. `sched.zig` uses the same engine entry points, so a scheduled task runs as an ordinary conversation.

---

*Case file grounded in the module's `//!` header and public API.*
