# llm

**File:** `src/worker/llm.zig`  
**Module:** `worker`  
**Description:** The worker's LLM client — transport splits by destination (loopback plain-http via the in-process httpc.zig socket client; hosted TLS via a curl child whose API key rides a `-K` config file), with `chat()` for one-shot completions and `complete()` for the agentic tool loop.

---

## Purpose Summary

Every model call the worker makes goes through this client. It loads no models: it builds request bodies, moves bytes, and parses replies. A loopback backend (a local Ollama) is spoken to in-process over raw sockets — no curl child (Defender kills those), no scratch files — while a hosted backend needs TLS the Zig control plane lacks, so those calls shell out to curl with the key in a config file so it never appears on the process argv. On top of transport it carries the process's entire token accounting (global meters, per-thread turn deltas, per-role cost buckets) and a startup capability probe that shapes how each backend is driven.

## Key Exports

- `Reply` + `chat(...)` / `chatTemp(...)` — one-shot system+user completion (temp variant sets temperature); `visionExtract(...)` — image bytes + instruction
- `ToolCall` + `Step` (`content`, `reasoning`, `calls`, `ok`, `truncated`) + `complete(...)` — the agentic entry point: a pre-built messages array + tools array → content OR parsed tool_calls; `truncated` marks a length-cut reply (load-bearing: a fenced file body in a cut reply is incomplete even though it reads clean)
- `completeStream(...)` + `DeltaKind` (`content` / `reasoning` / `tool_progress`) — streaming variant; tests cover both the SSE parser and the Ollama-native parser, including reassembling tool calls from streamed fragments
- Token meters — `tokens_in`/`tokens_out`/`tokens_in_free`/`tokens_out_free`/`calls_made`/`tokens_cached` (process-wide atomics folded from each response's `usage` block) and `TokUsage` + `tokensSnapshot()` (thread-local totals read as a delta = exactly one turn's usage)
- Per-role cost attribution — `RoleCost`, `RoleMax`, `roleCosts()`, `callLog()`, `callLogDropped()`, `resetAttribution()`: one bucket per (role label, model) so a trio-routed turn's tokens land on the model that actually served each role; drained by metrics.zig
- `Caps` + `capsSnapshot()` + `probeCapabilities(...)` — the startup backend probe (native tool support, thinking, context length); `recordLargeToolWall(...)`
- `isLocal(base_url)` — local endpoint detection; `fenceWrites(base_url, model)` — whether file-sized tool calls from this backend/model cannot be trusted and writes must be fenced
- `jstr(gpa, list, s)` — JSON string escaper that sanitizes invalid UTF-8 (borrowed by commons.zig and others)

## Dependencies

- `worker/httpc` — the in-process raw-socket HTTP client for loopback backends
- `worker/rate` — rate limiting
- `curl` (child process) — hosted TLS transport only; key via `-K` config file

## Usage Context

Called from every model-facing path in the worker: `run.zig` mind moments, the chat engine's turn loop, and helper passes in `tools.zig`. `commons.zig` imports it just for `jstr`. `metrics.zig` drains the per-role buckets at the turn's usage choke-point.

## Notable Implementation Details

- Probe-first: a probed capability always wins over the port/model-name heuristics; unprobed backends fall back to heuristics (tested). Per-model quirks self-heal — e.g. a temperature-constraint error rewrites the body and retries.
- Local **thinking** models get a max_tokens floor (2048) because hidden reasoning eats the budget before the answer; a plain relay model keeps the caller's value verbatim, so it never stalls generating filler.
- The per-call wall-clock cap is DERIVED from the output-token budget instead of one flat constant — a flat 90s cap structurally killed exactly the largest, most valuable generations (documented in-file from a real run).
- Ollama-native handling: `num_ctx` is pinned in options, argument objects are re-serialized into JSON-string tool calls, and the probed model context bounds the engine budget.
- `fenceWrites` fences a hosted backend only on measured text-emission evidence; a probed local backend that cannot parse file-sized tool calls is fenced from round 1.
- Thread-local turn accounting exists because each chat turn runs on its own thread — process-global atomics would cross-count concurrent turns.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
