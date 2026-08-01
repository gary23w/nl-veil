# dataset

**File:** `src/worker/dataset.zig`  
**Module:** `worker`  
**Description:** "Build dataset" — captures every LLM call and tool run into `{data}/sets/<id>/` in a shape a fine-tuning run consumes directly.

---

## Purpose Summary

The one honest place to record a training example is the LLM boundary: the exact request the engine sent (system doctrine + full conversation + prior tool results + the tools array) and the exact assistant output (visible content, hidden reasoning, structured tool calls). That pair *is* a supervised example — nothing inferred, nothing reconstructed. So `worker/llm.zig` calls `recordCall` at each of its four completion paths (OpenAI blocking, native blocking, streamed, pre-rendered raw prompt) and `worker/tools.zig` calls `recordTool` at its single dispatcher. Together they record how the model reasons, how it calls tools, and what those tools actually did.

On/off is a **file**: `<root>/RECORDING` holds the active set id. Swarm minds are separate processes (the supervisor injects `NL_SETS_DIR`), and a marker file is the one switch every process can read with no IPC and no restart. Each process re-stats it at most every 2s, so "am I recording?" costs an atomic load on the hot path. Everything is fail-quiet — a full disk must never break the user's turn.

## What a set contains

- `sft.jsonl` — **train on this.** OpenAI messages format per line: `{"messages":[…],"tools":[…]}`, the final message being the assistant turn with `content`, `reasoning_content`, and `tool_calls`.
- `by-model/<slug>.jsonl` — the same records sharded by the model that produced them (and every record carries `provider`/`base_url`, so "where the response came from" is queryable).
- `raw.jsonl` — verbatim request body + parsed response + timing, tokens, role label.
- `tools.jsonl` — every execution: name, verbatim args, the result the model read, ok, ms.
- `meta.json`, `README.md` — what the set is, and its format documented inside the set.

## Key Exports

- `configure` / `setSource` / `setsDir` — boot wiring (`NL_SETS_DIR` overrides the root)
- `start` / `stop` / `status` / `listInto` — the lifecycle the routes and CLI drive
- `recordCall` / `recordTool` — the two capture hooks
- `armed` — the atomic fast gate every hook checks first
- `jsonArrayInner` / `slug` / `hostOf` — the pinned pure parts

## Usage Context

Driven by `/api/v1/dataset[/start|/stop]` (main.zig), `veil dataset start|stop|status`, the desk Settings "BUILD DATASET" panel, and the web Settings panel. Sets are gitignored.
