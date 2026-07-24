# context

**File:** `src/worker/chat/context.zig`  
**Module:** `worker/chat`  
**Description:** Bounded LLM-context assembly for the server chat turn — projects the unbounded messages.jsonl history into a fixed budget instead of replaying the whole transcript.

---

## Purpose Summary

The durable conversation log grows without bound, but what is fed to the model each inference must stay inside its context window (replaying everything overflows the window and hits a hard 8 MiB read cliff on long chats). The projection: pin the original goal (the first user message, which anchors the whole arc), replay only a recency window of the newest turns, and report the gap so the caller can cover the dropped middle with a rolling summary plus relevance recall. Storage stays full — only the *context* is windowed. The module is pure + std-only so the windowing math is unit-tested directly; impure file reads use std.Io.

## Key Exports

- Budget constants: `HISTORY_WINDOW_BYTES` (28 KiB recency window), `HEAD_READ_BYTES`, `GOAL_PIN_CAP`, `CURRENT_MSG_PIN_CAP` (the live question is seeded verbatim as a safety net), `SUMMARY_INJECT_CAP`, `SUMMARY_SPAN_CAP` (max middle-span fed to one summary update), `WORKING_COMPACT_BYTES` (in-turn growth before compaction), `BYTES_PER_TOKEN` + `estTokens()` (a rough, model-agnostic proxy — there is no tokenizer).
- `HeadTail` / `readHeadTail(io, path, head_buf, tail_buf)` — positioned head+tail reads of a possibly large file; cost is O(head+tail) regardless of file size.
- `readSpanTailTrimmed` — the newest bytes of a span with any leading partial line trimmed.
- `View` / `computeView(head, tail, size, window_bytes)` — the recency-window view: pinned goal line, window bytes, absolute offsets, and a `gap` flag.
- `RecoveredCall` / `MarkupRecovery` / `looksLikeToolMarkup` / `contentBeforeMarkup` / `recoverMarkupCalls` — recovery of tool-call markup that models leak into the content channel.

## Dependencies

- `std` only.

## Usage Context

The caller (chat_engine.zig) parses the windowed JSON lines and owns the LLM-backed summary generation; `worker/run.zig` also imports it (as `cctx`). Compiled into the suite via `src/tests.zig`.

## Notable Implementation Details

- `computeView` trims the tail to a clean line boundary so every replayed line is a full JSON object; when the whole file fits, it replays verbatim with no pin and no gap.
- A goal line longer than the head read is *not* pinned as a truncated fragment (the parser would reject it and the goal would be dropped from both pin and summary) — instead `goal_end = 0` folds the whole goal into the rolling summary's coverage.
- Markup recovery handles two dialects seen in the wild: the DSML-style `invoke name="..."` / `tool_calls>` markup (anchored on ASCII substrings, robust to sentinel variations) and the hermes/Qwen `<tool_call>` + `<function=NAME>` + `<parameter=KEY>` style that DeepSeek endpoints fall back to under load. Both leak as prose, run no tool, and stall the drive loop — `recoverMarkupCalls` turns them into actual calls and strips the block from the content.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
