# metrics

**File:** `src/worker/metrics.zig`  
**Module:** `worker`  
**Description:** Per-ROLE LLM usage metering behind the desk Dashboard — every served chat turn appends one line per (role, model) to `{data}/u{uid}/_metrics/llm.jsonl`, and `GET /api/v1/metrics/llm` aggregates that file into what the Dashboard draws.

---

## Purpose Summary

Under the model trio a turn is served by up to three DIFFERENT models routed by call label (chat→coding, loop→prompting, plan/reflect/summary/ctxsum/compact/lesson→thinking). The old recorder wrote one line per turn stamped with whichever model armed it, so the thinking and prompting models' tokens were billed to the coding model's row. The split is now measured in llm.zig at the usage fold (where the call's label and its actual model are both in hand); this file drains and writes it. Two files answer different questions: `llm.jsonl` is per (role, model) per TURN (what the Dashboard aggregates); `calls.jsonl` is the per-CALL durable flight recorder — "which model served THAT call, and why did it take 40s".

## Key Exports

- `beginTurn(uid, model, base_url, is_sched, now_s)` — arm this thread's turn context at engine.runTurn entry (strings copied; also resets llm attribution so a recycled thread never bills its predecessor's calls)
- `hostOf(base_url)` — the host[:port] identity of a provider (paths differ per API shape; keys must never appear here)
- `record(app, tokens_in, tokens_out, tokens_cached, now_s)` — append this turn's usage: one row per (role, model) the turn used, plus the buffered flight lines; a no-op on an unarmed thread or a zero-token turn
- `endTurn()` — disarm, and flush any calls made AFTER the engine's usage snapshot (the deferred rolling-summary refresh is real spend)
- `getLlm(app, req, res)` — `GET /api/v1/metrics/llm`: per-(model, base), per-(role, model, base), a 14-local-day series, and totals; a missing file is empty aggregates, never an error
- `DAYS` — the Dashboard's activity window (14 local days)

## Dependencies

- `worker/llm.zig` — `roleCosts()` / `callLog()` / `resetAttribution()`, the per-role attribution measured at the usage fold
- `gateway/http.zig` — `App`, torn-write-free `appendFile`, `jstr`; `httpz` for the endpoint
- `worker/sched.zig` — `localOffsetSecs()` for local-day bucketing

## Usage Context

`worker/chat/engine.zig` arms/records/disarms around each turn (the thread-local context rides the invariant that a turn runs start-to-finish on one thread); `main.zig` wires the GET route. Hive/cast minds are NOT metered here yet — they burn tokens on their own threads outside runTurn.

## Notable Implementation Details

- The engine reaches its usage choke-point from nine completion paths with a CUMULATIVE delta, so the context tracks `billed_*` and reconciles: a repeat `record()` on the same turn writes nothing twice; whatever the delta covers that no role bucket does lands as one `"other"` row against the armed model, so file totals always reconcile with real spend.
- A cached-only remainder is marked billed WITHOUT emitting a row — there is no in/out to report, but those tokens must not be counted again by a later flush.
- `ms` per row is PROVIDER latency summed over the bucket's calls, not turn wall clock — roles run in sequence, so wall clock would make each model look three times slower. Legacy rows (no role, no ms) still parse: role "", calls 1, `s` wall-clock fallback.
- `calls.jsonl` rotates to `calls.prev.jsonl` past 32 MB (exactly one previous window stays inspectable); dropped flight lines undercount CALLS only — token totals in llm.jsonl stay whole.
- `endTurn()` has no App parameter (engine.zig owns that signature, calling from a `defer`), so the App is cached from the first `record()`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
