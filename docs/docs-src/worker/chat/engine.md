# engine

**File:** `src/worker/chat/engine.zig`  
**Module:** `worker/chat`  
**Description:** The chat brain — the server-side agentic turn loop. Given one user message it runs a bounded tool-calling loop against the caller's chosen model and streams progress into the conversation's on-disk store. This is where the chat "brain" lives now: clients (veil-desk, `veil chat`) are thin, and the whole turn runs here.

---

## Purpose Summary

`engine.zig` is the write twin of `service.zig`'s read-only conversation routes. `postMessage` claims a per-conversation turn slot and hands the message to this loop, which perceives the goal and live state, calls tools, and settles an answer — writing everything into the same per-conversation tree the read routes serve:

```
{data}/u{uid}/_chat/convs/{conv}/
    messages.jsonl   // one JSON object per line: {role,content,kind,ts}  (user + final assistant turns)
    events.jsonl     // one JSON object per line: {kind,...}              (live turn narration for the poll)
    control.jsonl    // cooperative control ops the client appends (stop / steer)
```

The build tools the loop's calls run route through the SAME workdir a hive cast for this conversation spawns in (`{data}/u{uid}/_chat/builds/{conv}`), so chat and a cast co-edit one tree with one micro-VCS history. Ownership is structural: every path is built from the caller's own `uid`, so a turn can only ever touch its own conversation.

## The turn loop

- **Tool rounds per step (`MAX_ITERS = 24`).** The hard ceiling on tool-calling round-trips inside one settled answer — enough for a real single-turn build (many `write_file` / `read_file` / `edit_file` rounds) without committing a raw "reached the step limit" string mid-build.
- **Drive steps (`DRIVE_MAX = 6`).** With auto-loop OFF, the turn may still take a few follow-through drive steps; a plain question settles after one. The client's Stop reaches the turn between steps.
- **Auto-loop tiers (`loop: 0|1|2` on the `/messages` body).**
  - `LOOP_OFF (0)` — a normal bounded turn.
  - `LOOP_ON (1)` — the veil writes its own next step and drives toward the goal until DONE, no-progress, or the cap (`LOOP_MAX_STEPS`).
  - `LOOP_AFK (2)` — the persistent tier: it never accepts an end state (DONE folds into a re-verify-and-extend, re-grounded to the goal), the repeat guard is skipped, and only the client's Stop ends it (`AFK_MAX_STEPS` is a pure runaway backstop).

Between drive steps and before each tool the loop drains `control.jsonl`: `{"op":"stop"}` ends the turn promptly; `{"op":"steer","text":...}` folds the guidance in as a user message so a running turn can be redirected without restarting it.

## The spend ceiling compacts and continues

A turn has a cumulative INPUT-token ceiling (`TURN_TOKEN_CEILING_DEFAULT = 400_000`, `NL_TURN_TOKEN_CEILING`, `0` disables) — a runaway backstop, not a budget; the measured runaway that motivated it was 1.83M input tokens in one turn. Crossing it used to END the turn, which was right about the spend and wrong about the work: the turn's whole working span died with it, `refreshSummary` does not run on that path, and the next turn replayed only the original request plus a one-line notice. It started over and hit the same wall the same way.

Now the ceiling settles a **segment**, not the chat:

- **Distil.** One bounded call on the thinking role (`turnHandoff`) reads both ends of the working log — `HANDOFF_CTX_HEAD_BYTES = 6 KiB` + `HANDOFF_CTX_TAIL_BYTES = 12 KiB`, joined by an elision marker — and writes four labels under `HANDOFF_MAX_BYTES = 1400`: ESTABLISHED / ON DISK / RULED OUT / NEXT. *ON DISK* is grounded in the turn's own file ledger, so it is verified rather than claimed; *RULED OUT* and *NEXT* are the two fields a compression prompt has no reason to write and are exactly what stops the next attempt repeating the first.
- **Fuse, don't add a row.** The distillation is fused into the single `role:"system"` / `kind:"engine"` row the `.stopped` arm already writes (`TOKEN_CEILING_NOTE`). `seedLines` replays only the newest engine row, so a second row would annihilate it and a new `kind` would escape `dropEngineRows` and be folded permanently into the rolling summary. A streak of cut turns collapses to exactly one row with no de-duplication logic.
- **Compact and roll.** `conv_buf` is truncated back to the assembled prefix — the enormous span that tripped the ceiling is DROPPED — and the segment re-seeds from the fused state as a system turn plus one user turn (`CONTINUE_SEGMENT_MSG`). `token_cap` is re-anchored per segment: the ceiling is an absolute thread reading, not a delta, so a turn that rolls past one must move its own goalposts or the very next inference re-trips it instantly. That reset is the economic argument and why this is not simply "raise the ceiling" — the ceiling fires because every round re-uploads a context that GREW.
- **The allowance is earned.** `TURN_CONTINUE_MAX_DEFAULT = 3` (`NL_TURN_CONTINUE_MAX`; `0` restores settle-and-wait exactly) is the floor. A segment that grew the file ledger or the network-call ledger buys one more pass, up to `TURN_CONTINUE_HARD_MAX_DEFAULT = 10` (`NL_TURN_CONTINUE_HARD_MAX`). A segment that only re-read its own context moves neither ledger and earns nothing, so a spinning turn still settles at 3 exactly where it did before, while a productive one may spend up to eleven segments of the per-segment ceiling.
- **Two cuts deliberately do NOT roll.** The **loop guard** (`LOOP_STOP_NOTE`): its pathology is repetition, and handing that a fresh context to repeat itself in is the one response guaranteed not to help. And a **failed distillation** (`handoff.len == 0`): rolling with nothing to re-ground from is the restart-from-scratch this exists to stop, minus the human noticing.
- **Safety.** Every boundary emits a visible status carrying the pass count and re-checks Stop (`stopRequestedSince`). The re-seed is built COMPLETE in scratch and only then spliced, so any allocation failure breaks into the unchanged settle-and-return path and a half-written re-seed can never be dispatched. `engine_note` is non-empty at exactly the two engine cuts and empty at every user-Stop return — someone who pressed Stop asked to stop SPENDING.

The same distillation is also pressed into neuron-db as a durable [resume anchor](#doc=worker/continuity), which is what carries a cut across a surface whose next unit of work opens a DIFFERENT transcript — a [scheduled run](#doc=worker/sched) gets a fresh `conv_dir` every time, so the engine row alone would never be read. `continuity.read` bids on the workspace's `continuation` channel while the turn is assembled; `continuity.clear` runs on every normal completion, so a healthy conversation carries no anchor and its prompt is byte-identical to before.

## Context through the workspace

Every non-transcript block the turn injects — durable memory, the tool digest, the trust belt, image OCR, relevance recall, belt corrections, family context, plugin hooks, the file ledger — bids into the [prompt workspace](#doc=worker/chat/workspace) instead of appending ad hoc: fixed render order per channel (byte-compatible with the prompt-prefix-cache layout), per-channel byte budgets with whole-block lowest-score-first drops, a provenance receipt on each admitted block, and one decision line per turn in `{conv}/workspace.jsonl`.

Recall itself is scored: the neuron CLI's `recallscored` returns top-k facts **with numbers**, the top hit's coverage rides the bid as measured confidence, facts the store marked contested arrive labeled with the disagreeing sibling, and a sentinel-gated `memverify` completion on the thinking role annotates doubtful facts before the answering model reads them (`NL_MEM_VERIFY=0` disables; verdicts never delete). An older neuron binary degrades to the legacy prose recall byte-identically.

## Concurrency & lifecycle

- One in-flight turn per conversation. `tryBeginTurn` claims the slot (so `postMessage` can answer `409` before persisting anything); `spawnTurn` fires the turn on a raw detached thread and owns releasing the slot on every completion path.
- The turn runs off the httpz worker thread and writes frames to `events.jsonl` as it goes, so the client streams live via `/events` instead of blocking on one long response.
- Raw-thread sleeps (`sleepMsRaw`, Win32 `Sleep` on Windows) because `io.sleep` throws on a non-Io thread and a swallowed error would busy-spin a core.

## Dependencies

- `worker/tools` — the tool surface the loop calls (write/read/edit/search/shell/…)
- `worker/llm` — the model call machinery (streaming completions)
- `worker/chat/context` — the recency window + pinned goal + rolling summary that keeps the prompt bounded
- `worker/continuity` — durable resume anchors: press on a cut, read at assembly, clear on a clean finish
- `worker/chat/plan` — task decomposition into routed subtasks the drive loop walks
- `worker/deploy/service` — casting a hive for the conversation from inside a turn
- `worker/oscillation`, `gateway/http` (App)

## Usage Context

Entered only through `chat_service.postMessage`. ON by default; the kill switch `VEIL_CHAT_BACKEND=0` returns `501`, which a client treats as a signal to fall back to a local engine. Open to every authenticated user. The per-role gating this note used to anticipate has landed: `tools.execute` refuses on `ctx.caps == .sandboxed` as its first statement, before any tool-specific logic, so there is exactly one place a capability decision is made. Non-admins run `.sandboxed`, admins `.full`, and the turn's advertised tool schema is trimmed to match — a sandboxed caller is never offered a tool that could only come back as a refusal. Scheduled tasks (`sched.zig`) enter the same `tryBeginTurn` + `spawnTurn` path, so a scheduled run is a real conversation.

---

*Case file grounded in the module's `//!` header and public API.*
