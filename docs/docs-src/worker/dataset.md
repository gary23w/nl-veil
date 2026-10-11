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

## Rolling parts

No file that is still being written grows past `PART_MAX` (16 MiB). The append that would cross it first renames the live file to `<name>.<YYYYMMDD-HHMMSS.mmm>-<seq>-t<thread>.jsonl` (UTC; a rename, no copy) and starts a fresh `<name>.jsonl`. An archived part is never written again.

The reason is Windows Defender: real-time protection rescans a file in full each time it is modified and closed. On 2026-10-11 a set recording since August held `raw.jsonl` at 511 MB, `sft.jsonl` at 526 MB and `by-model/` at 526 MB. Every model call appended a few dozen KB, and Defender re-read the files in bursts of 0.9 to 1.3 GB/s: about 45 bursts of roughly 1 GB in the 150 seconds around one prompt, enough to stall the whole machine when memory was tight. With parts, a rescan covers at most 16 MiB.

Records are unchanged and never split across parts. For one stream, concatenate `<name>.*.jsonl` in name order and then `<name>.jsonl`, for example `cat sft.*.jsonl sft.jsonl`. The stamps sort before the live file's name. For `by-model/`, where one model's slug can be a prefix of another's (`qwen2` and `qwen2.5-coder_7b`), match the stamp pattern rather than a bare glob.

Appends are serialized within a process by an io-free spin-and-yield lock (never `std.Io.Mutex`, whose contended path parks plain threads on the runtime's alert). The write offset is read after opening the file, so another process that appended or rolled in between is never overwritten and never leaves a gap.

## Key Exports

- `configure` / `setSource` / `setsDir` — boot wiring (`NL_SETS_DIR` overrides the root)
- `start` / `stop` / `status` / `listInto` — the lifecycle the routes and CLI drive
- `recordCall` / `recordTool` — the two capture hooks
- `armed` — the atomic fast gate every hook checks first
- `jsonArrayInner` / `slug` / `hostOf` — the pinned pure parts

## Usage Context

Driven by `/api/v1/dataset[/start|/stop]` (main.zig), `veil dataset start|stop|status`, the desk Settings "BUILD DATASET" panel, and the web Settings panel. Sets are gitignored.
