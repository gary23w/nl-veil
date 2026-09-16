# context

**File:** `src/worker/chat/context.zig`  
**Module:** `worker/chat`  
**Description:** Bounded LLM-context assembly for the server chat turn — projects the unbounded messages.jsonl history into a budget sized for the model that reads it, instead of replaying the whole transcript; keeps the append-only digest ledger that lets a conversation run without end.

---

## Purpose Summary

The durable conversation log grows without bound, but what is fed to the model each inference must stay inside its context window (replaying everything overflows the window and hits a hard 8 MiB read cliff on long chats). The projection: pin the original goal (the first user message, which anchors the whole arc), replay only a recency window of the newest turns, and report the gap so the caller can cover the dropped middle with a rolling summary plus relevance recall. Storage stays full — only the *context* is windowed. The module is pure + std-only so the windowing math is unit-tested directly; impure file reads use std.Io.

## Key Exports

- Budget constants: `HISTORY_WINDOW_BYTES` (the stock 28 KiB recency window), `HEAD_READ_BYTES`, `GOAL_PIN_CAP`, `CURRENT_MSG_PIN_CAP` (the live question is seeded verbatim as a safety net), `SUMMARY_INJECT_CAP` (the stock 6 KiB summary), `SUMMARY_CHUNK_BYTES` (the most one fold reads) + `SUMMARY_CHUNKS_PER_TURN`, `WORKING_COMPACT_BYTES` (in-turn growth before compaction), `BYTES_PER_TOKEN` + `estTokens()` (a rough, model-agnostic proxy — there is no tokenizer).
- Capacity-scaled budgets: `Capacity` (small / mid / large, the same integers as `modelcfg.Tier`), `summaryInjectCap(win_bytes, cap)`, `historyWindowCap(cap)`, `factsBudget(win_bytes, cap)`, `summaryChunkBytes(summarizer_win_bytes, summary_cap)`, `FoldShape` / `foldShape(cap, summary_cap)` — every number the engine's `ContextPlan` is built from, as pure functions of a window size and a capacity.
- The digest ledger: `DIGEST_FILE` (`digest.jsonl`), `DIGEST_SCAN_BYTES`, `Note` / `splitNote(reply)` (a fold's reply split into its summary and its FACTS), `cleanFactLines`, `digestRecord` (one append-only record), `readTailTrimmed` (the newest bytes of the ledger, whole records only), `cueTokens` + `selectFacts(gpa, tail, cue, budget)` (the projection: newest lines plus the lines closest to the live question, under a budget, no model call).
- `HeadTail` / `readHeadTail(io, path, head_buf, tail_buf)` — positioned head+tail reads of a possibly large file; cost is O(head+tail) regardless of file size.
- `HeadSpan` / `readSpanHeadTrimmed(io, path, from, to, buf)` — one line-aligned chunk from the OLDEST end of an uncovered span, reporting exactly how many bytes it consumed (the summary cursor advances by that and nothing else).
- `View` / `computeView(head, tail, size, window_bytes)` — the recency-window view: pinned goal line, window bytes, absolute offsets, and a `gap` flag.
- `RecoveredCall` / `MarkupRecovery` / `looksLikeToolMarkup` / `contentBeforeMarkup` / `recoverMarkupCalls` — recovery of tool-call markup that models leak into the content channel.

## Dependencies

- `std` only.

## Usage Context

The caller (chat_engine.zig) parses the windowed JSON lines and owns the LLM-backed summary generation; `worker/run.zig` also imports it (as `cctx`). Compiled into the suite via `src/tests.zig`.

## The transcript ledger — a chat without end

A conversation that never ends cannot live in one rewritten summary. Every fold used to *replace* the running summary with a fresh 250-word rewrite, so whatever a rewrite failed to restate was gone: at turn 500 the decision made at turn 5, the path given at turn 12, the preference stated at turn 30. The transcript was never truncated, but nothing the model was shown could reach that far back. Three layers now project the whole transcript into a window of any size, each bounded by the model that reads it:

- **The recency window** — the newest turns verbatim (`computeView`; the engine sizes it).
- **The rolling summary** — one rewritten narrative of everything older, now capacity-sized.
- **The digest ledger** — append-only. Every fold *also* lists the concrete facts its chunk established (decisions, preferences, names, paths, values) and the engine appends them as one `{conv}/digest.jsonl` record that is never rewritten. At assembly the ledger's newest `DIGEST_SCAN_BYTES` are read back and *projected* for the live question by `selectFacts`: every line deduplicated (a repeat keeps its newest position), the newest lines until half the budget is spent, then the lines lexically closest to the question and the pinned goal, then more of the recent past — rendered oldest-first as one system turn right after the summary. No model call; the read is O(1) in the size of the conversation.

A fact in the ledger decays with nothing. The summary carries the narrative, the ledger the specifics, the window the present. The workdir's own `.veil-facts.md` (tool-established values within a turn) now evicts its oldest lines when full instead of going silent at its cap.

**Sized to the model, in both directions.** Every budget is a pure function of a window size and a `Capacity` (the engine maps `modelcfg.Tier` onto it): the summary is a sixteenth of the window between a 2 KiB floor and a capacity ceiling (6 / 10 / 16 KiB), the facts block a twenty-fourth (4 / 8 / 12 KiB ceilings), the recency window grows past the stock 28 KiB only for a mid or large reader and only when a full working span still fits beside it (48 / 64 KiB ceilings), and a fold's input chunk is sized to the *summarizing* model's window after reserving room for the summary it reads and the summary plus facts it writes back. `foldShape` asks a small summarizer for 200 words and 15 facts, a frontier one for up to 900 words and 50 facts, bounded by the byte cap it must fit under. A small-parameter model with a huge window keeps small-model budgets: it is never handed a prompt it cannot follow. A frontier model with a 1.3M-token window is never held to an 8k model's memory.

## Notable Implementation Details

- `computeView` trims the tail to a clean line boundary so every replayed line is a full JSON object; when the whole file fits, it replays verbatim with no pin and no gap.
- A goal line longer than the head read is *not* pinned as a truncated fragment (the parser would reject it and the goal would be dropped from both pin and summary) — instead `goal_end = 0` folds the whole goal into the rolling summary's coverage.
- Markup recovery handles two dialects seen in the wild: the DSML-style `invoke name="..."` / `tool_calls>` markup (anchored on ASCII substrings, robust to sentinel variations) and the hermes/Qwen `<tool_call>` + `<function=NAME>` + `<parameter=KEY>` style that DeepSeek endpoints fall back to under load. Both leak as prose, run no tool, and stall the drive loop — `recoverMarkupCalls` turns them into actual calls and strips the block from the content.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
