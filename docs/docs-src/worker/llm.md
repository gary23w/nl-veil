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
- `initQuirkStore(io, dir)` — points the learned provider-quirk table at its durable `{dir}/provider_quirks.jsonl` and loads every prior lesson; called at boot by main.zig (server/CLI) and run.zig (each swarm worker) against the same data dir

## Dependencies

- `worker/httpc` — the in-process raw-socket HTTP client for loopback backends
- `worker/rate` — rate limiting
- `worker/browser/util.zig` — `sleepMs` for the stream tail loop's 20 ms poll and `retryWait`'s quarter-second slices. Not `io.sleep`: on Windows that parks a plain thread (the chat turn's) on the Io runtime's per-thread alert, and a stray alert there is undefined behaviour in the ReleaseFast build. The poll keeps its pace (~31 ms a lap at the default timer tick, either sleep).
- `curl` (child process) — hosted TLS transport only; key via `-K` config file

## Usage Context

Called from every model-facing path in the worker: `run.zig` mind moments, the chat engine's turn loop, and helper passes in `tools.zig`. `commons.zig` imports it just for `jstr`. `metrics.zig` drains the per-role buckets at the turn's usage choke-point.

## Notable Implementation Details

- Probe-first: a probed capability always wins over the port/model-name heuristics; unprobed backends fall back to heuristics (tested). Per-model quirks self-heal — e.g. a temperature-constraint error rewrites the body and retries — and the lessons are durable: each learn writes through to `provider_quirks.jsonl` in the data dir, so neither a server restart nor a fresh swarm worker re-pays a failed round-trip a previous process already paid (never-lose merge: file fields only fill gaps, RAM lessons stay authoritative).
- **Thinking models get a max_tokens floor** because hidden reasoning eats the budget before the answer; a plain relay model keeps the caller's value verbatim, so it never stalls generating filler. A probed-local thinking model takes `LOCAL_MIN_TOKENS = 2048` up front. A **hosted** reasoning model is caught by a third transport-level heal beside `healParamError` and `healEchoError`, on a signature no vendor owns: the call succeeded, there were no tool calls, reasoning is present, content is empty after trim, and `finish_reason == "length"`. That is a model whose reasoning does not fit in what the caller asked for, and no retry at the same size will change it — so `learnReasoningBudget` records the model, the budget is raised to `@max(budget * 8, REASONING_MIN_TOKENS = 8192)`, and the call retries ONCE with healing off. Every later call gets the floor from `effTokens` up front, so the round-trip is paid once, and the lesson persists in `provider_quirks.jsonl` as a `reasoning_budget` flag on the Quirk records (unknown fields are ignored on parse, so no migration).
  This is learned rather than named because the name test was already there and already wrong — `isThinking` answered false for a model that was visibly streaming `reasoning_content`. The engine asked for 768 tokens to distil a turn's continuation state, the answer never fit behind the reasoning, and an empty result is indistinguishable from "the model had nothing to say", so the engine banked a bare compaction note with no state and the next turn began from nothing. Ten turns out of eleven on a live run.
- The per-call wall-clock cap is DERIVED from the output-token budget instead of one flat constant — a flat 90s cap structurally killed exactly the largest, most valuable generations (documented in-file from a real run).
- Ollama-native handling: `num_ctx` is pinned in options, argument objects are re-serialized into JSON-string tool calls, and the probed model context bounds the engine budget.
- `fenceWrites` fences a hosted backend only on measured text-emission evidence; a probed local backend that cannot parse file-sized tool calls is fenced from round 1.
- Thread-local turn accounting exists because each chat turn runs on its own thread — process-global atomics would cross-count concurrent turns.
- **A chat turn's retry budget** (`RETRY_MAX = 10`, `armRetries`/`disarmRetries`, armed by the engine per turn): on a budgeted thread a hosted call that fails with ANY error — a 429, a 5xx, a transport drop, and just as much an HTTP 401 `Authentication error` or a rejected request — is retried after a climbing wait (`RETRY_WAITS_S`: 5, 10, 15, 20, 30, 30, 45, 45, 60, 60 s — 320 s in all), each wait announced through `retry_notify` as a `provider failed (…): retrying in Ns (i/10)` status frame, where `(…)` is `errHead`: the HTTP status plus the provider envelope's own `message` (`HTTP 401: Authentication error`), else the error's first line clipped to 72 bytes. The count is per provider (base_url + model) and of failures IN A ROW: a reply restores it, so a hiccup costs one wait, a provider that is down for good costs one ladder before every later call to it fails at once, and a misconfigured auxiliary model cannot spend the coding model's retries. Before each retry `retry_rekey` lets the engine hand over a re-resolved credential (the Cloudflare login's refreshed access token — the 401 that used to end long turns), and `retryWait` polls `retry_abort` between quarter-second slices of every wait so a chat Stop ends the ladder at once. When the budget is spent (`retryExhausted`) the failure surfaces: the chat call's failure ends the turn with a `gave up after 10 retries` error frame. An unarmed thread (the swarm's workers) and a LOCAL endpoint on any thread keep the older ladder — three retries per call after 10, 20 and 30 s (`RETRY_WAITS_TRANSIENT_S`), transient errors only (`isTransientLlmError`). Both ladders live in `complete()`, which a failed stream reaches through `completeStream`'s fallback; `chat()`/`chatTemp()`/`visionExtract()` and the Ollama-native path never enter either.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
