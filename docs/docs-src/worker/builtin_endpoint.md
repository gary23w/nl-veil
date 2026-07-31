# builtin_endpoint

**File:** `src/worker/builtin_endpoint.zig`  
**Module:** `worker`  
**Description:** The built-in engine's loopback HTTP surface — the native local dialect (`/api/version`, `/api/show`, `/api/generate` raw, `/api/chat`) plus `/v1/chat/completions`, every route under `/builtin` and gated by the per-boot bearer.

---

## Purpose Summary

A separate 127.0.0.1-only listener (not routes on the main server) because swarm minds are SUBPROCESSES — they reach the engine over TCP exactly like they reach any local model runtime — and because the main server may bind all interfaces while this must never be. It speaks the dialect the llm client already prefers: `/api/version` marks it native, `/api/show` reports family/window/params, `/api/generate` takes a pre-rendered raw prompt verbatim (llm.zig's engine-side renderer is the caller), and `/api/chat` renders messages+tools through `gemma4.renderPrompt` — the byte-verified wire format the model was trained on — so chat and swarm, streamed and blocking, all run the SAME renderer. Streaming is chunked NDJSON with a channel machine that routes thought-channel text to `thinking` deltas, swallows tool-call blocks (the parsed calls follow as one line), and never leaks a split wire-format marker.

## Key Exports

- `start` — bind (NL_BUILTIN_PORT or a small scan), serve from a detached thread, report the port into builtin.zig
- `ChanMachine` — the streaming channel router (public for its tests)

## Dependencies

- `httpz` (vendored) — the listener; `res.chunk()` carries the NDJSON/SSE streams
- `worker/builtin.zig` — the Engine interface + secret/port state
- `worker/gemma4.zig` — rendering + completion parsing
- `worker/llm.zig` — `jstr`

## Usage Context

Started from main.zig boot only when `-Dbuiltin` compiled the engine in; tests drive every handler against a mock Engine with no weights and no C.
