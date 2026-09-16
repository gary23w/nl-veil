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

## A chat without end — the context plan

One `ContextPlan` per turn sizes the whole projection of the transcript, from two models: the coding model *consumes* the prompt (its live served window, else the catalog's `context_window`, else the id heuristic; its capacity is `modelcfg.senseModel`'s tier), and the thinking model *writes every fold*. `planCore` is the arithmetic, on plain numbers; `contextPlan` resolves the two models. The plan is threaded into both `assembleHistory` and `refreshSummary`, which must agree on where the recency window starts or the band between them belongs to neither — the bug the single `historyWindowBytes` was written to close, and which the plan closes structurally.

What the plan carries: `hist_win` (the recency window — tightened for a small window as before, and now *scaled up* to `cctx.historyWindowCap` for a mid or large reader when the window still holds a full stock working span beside it, so a 32k model keeps the window it had and a 128k frontier model replays 64 KiB), `summary_cap` (the rolling summary's injected and stored size — the smaller of what the reader holds and what the summarizer can write back), `facts_budget` (the digest ledger's projection), `chunk_bytes` (what one fold reads, sized to the summarizer's window rather than the flat 32 KiB an 8k local model could never take), and `shape` (the words, FACTS lines and completion budget the fold is asked for). A trace line per turn records all of it, so a chat that forgets is diagnosed from what it was allowed to hold.

Every fold (`summarizeInto`, label `ctxsum`, thinking role) now writes two sections — SUMMARY, then FACTS — and `refreshSummary` appends the FACTS to `{conv}/digest.jsonl` (`digestAppend`) before the summary that mentions them is rewritten for the last time. `assembleHistory` projects that ledger for the live question (`injectFactsLedger` → `cctx.selectFacts`) right after the summary, under `facts_budget`, with no model call. A fold that writes no FACTS line is the pre-ledger fold exactly; an empty summary is a failed fold, so the cursor stays put and the chunk is retried. The digest ledger rides the R2 backup beside `messages.jsonl` and `context.json`. See [context](#doc=worker/chat/context) for the ledger's projection rule and every budget's derivation.

## Context through the workspace

Every non-transcript block the turn injects — durable memory, the tool digest, the trust belt, image OCR, relevance recall, belt corrections, family context, plugin hooks, the file ledger — bids into the [prompt workspace](#doc=worker/chat/workspace) instead of appending ad hoc: fixed render order per channel (byte-compatible with the prompt-prefix-cache layout), per-channel byte budgets with whole-block lowest-score-first drops, a provenance receipt on each admitted block, and one decision line per turn in `{conv}/workspace.jsonl`.

Recall itself is scored: the neuron CLI's `recallscored` returns top-k facts **with numbers**, the top hit's coverage rides the bid as measured confidence, facts the store marked contested arrive labeled with the disagreeing sibling, and a sentinel-gated `memverify` completion on the thinking role annotates doubtful facts before the answering model reads them (`NL_MEM_VERIFY=0` disables; verdicts never delete). An older neuron binary degrades to the legacy prose recall byte-identically.

## The recall overlay

Unlike the blocks above, the [recall overlay](#doc=worker/chat/overlay) never bids into the workspace: it is a per-turn `hyperspace.Field` of this conversation's memory that rides one inference at a time.

- **Built before the drive loop**, unless `NL_MEM_OVERLAY` is `0`/`false`. `NL_HYPERSPACE_CAP` sizes the field (default `DEFAULT_CAP` = 256 here) and `NL_MEM_OVERLAY_BYTES` the rendered lines (default 900). The goal heads every cue. The seed is one `assocAcross` pull (k = 48) around the goal over the conversation's recall family (`scopeFamilyBase`) — the overlay's only seed subprocess — plus the YOUR MEMORY block and the file ledger. `injectDurableMemory` returns the block it bid, so the overlay seeds from the same masked text the prompt shows.
- **Rendered around the streamed chat call.** `runInnerAgentic` settles the field (`render()`), appends the block to `conv_buf` as the last `role:"system"` message, and shrinks `conv_buf` back to its prior length the moment `llm.completeStream` returns, so the block never reaches the transcript, a compaction or a later upload (a test pins the working context byte-identical). No auxiliary call carries it.
- **Fed from engine-held strings.** The model's narration and each tool call (`noteThought`, `noteCall`, with `observeFiring` on both to catch a line the model used), each finding note the moment it is minted for the store (`noteFinding` — recallable next round, no subprocess), the head of each tool result (`noteResult`), and each drive step or plan subtask instruction (`noteThought`).
- **At turn exit** the fired `[conv]` lines are strengthened in the conversation's partition (`strengthenFired` → `Mem.strengthen`, at most 8 spawns), then one `chatmem` log line records renders, lines shown, fired, inhibited and strengthened.

## Durable memory is an engine-observed event

A reply's `REMEMBER:`/`FORGET:` lines are applied to the user's store (`{data}/u{uid}/.veil-desk/memories.jsonl`) and stripped from the reply before reflect (`processMemoryDirectives`); a reply that was only directives shows `(noted — saved to your memory)`. Stripping used to leave no trace of the change in the working context, and the YOUR MEMORY block is assembled once per turn, so every later reader of the turn saw a stale fact beside a reply that never mentioned changing it: the step picker named the directive itself as the next step and escalated to hand-editing the store. Now:

- **The engine says what it did.** Each applied batch threads a `role:"system"` row into `conv_buf` directly under the reply (`memoryUpdateRow`: `[engine: durable memory updated — forgot "…"; remembered [cat] …`, then that the store already holds the change and needs no further step), with credential values masked by `appendFactShown`, the policy the YOUR MEMORY block uses. `emitMemoryUpdated` writes a status frame (`memory updated — N directive(s) applied`) and one `{"kind":"memory","text":"updated"}` frame from both apply sites; the desk re-reads its Memory tab's store on that frame.
- **A memory directive is never a drive step.** A step-picker proposal naming `REMEMBER:`, `FORGET:` or `memories.jsonl` (`memoryDirectiveShaped`, case-sensitive) has its bare directive lines applied directly. It counts as DONE once the turn has recorded a change or has already been asked to once; a turn that has recorded nothing gets one engine-framed step (`MEMORY_STEP_NUDGE`: reply with only the bare lines — no prose, tools or file edits) with the proposal appended under it, never the proposal as the instruction. `LOOP_QUESTION`, the non-AFK drive question, states the rule.
- **Dressing and a byte-order mark hide nothing.** `memoryDirective` finds the keyword after list markers, blockquotes, emphasis and code spans (`- **FORGET:** …`), though it must still open the line. The engine's store readers (`injectDurableMemory`, `durableMemoryHas`, `forgetDurableMemory`) all go through `durableLine`, which strips a UTF-8 BOM — behind one, the oldest memory was invisible to the prompt, to dedup and to `FORGET:`, and the forget rewrite kept the mark.

## A failed model call: ten retries, then the chat stops

`runTurn` arms the per-turn retry budget in [llm](#doc=worker/llm) (`llm.armRetries()`, disarmed at exit) and registers the three hooks its ladder calls. Each reads thread-locals the turn sets (`turn_app`, `turn_uid`, `turn_ctrl_cursor`), so it acts only on a turn's own thread.

- `retry_notify` → `llmRetryStatus`: each wait lands on the turn as a status frame (`provider failed (HTTP 401: Authentication error): retrying in 20s (4/10)`), account ids scrubbed (`scrubAccountIds`) as in the error frame.
- `retry_abort` → `llmRetryAbort`: polled between the quarter-second slices of a wait; a `{"op":"stop"}` in `control.jsonl` past the turn's cursor ends the ladder at once.
- `retry_rekey` → `llmRetryRekey`: for a Workers AI endpoint (`api.cloudflare.com` and `/ai/` in the base URL) it re-resolves the user's Cloudflare login through `cf_oauth.resolveToken`, which refreshes an access token at or near expiry, and hands the key over only when it is for the same endpoint and differs from the key that failed — the retry that can land on a mid-turn 401. Anything else returns null and the retry goes out unchanged.

When the chat call still fails with its provider's budget spent (`llm.retryExhausted`), the error frame reads `gave up after 10 retries — <head>` (`llm.RETRY_MAX`) and the turn ends.

## A client-mode turn: which tools run on the client

A turn posted with `tool_client:true` (the desk and `veil chat` send it, and `runTurn` honours it for an admin only) hands its mind tools to the client, so file, shell and code tools act on the user's machine. `delegateTool` emits a `tool_request` frame and waits on `/tool_result`. `clientRoute` names the exceptions: tools whose authority is a credential the server holds for the turn, which the client executor (`veil exec-tool`) is never handed.

- **`get_credential` runs here.** Its store is the server's `memories.jsonl`.
- **The `cf_` family runs here** (`cfClientTool`), because its token must never ride a `tool_request` frame. What crosses instead is the one file a call touches ([cftools](#doc=worker/cftools) `fileUse`), over the [sync](#doc=worker/chat/sync) channel.
  - Upload: `stageClientFile` runs the same-disk probe. On another disk it pulls the client's copy into the server's copy of the workdir, skipping the pull when the manifest hash already matches. If the client does not answer or does not have the file, the call is refused with nothing sent to Cloudflare, and the server's older copy is never uploaded in its place.
  - Download: once the verb sets `ToolCtx.cf_wrote`, `carryWrittenFile` pushes the file with `file_sync` and reads it back with `file_pull`. A file that is empty, binary, over `cync.FILE_CAP`, or not read back byte-identical gets an `(engine: …)` note that it is not on the user's machine. A push gets no answer of its own, so the read-back is what catches a write that failed or a client that did not apply it (desks before the background-sync fix skipped pushes for a conversation that was not on screen).
  - Both keep `delegateTool`'s client-absence latch: a client that already proved absent this turn is not waited on again, silence counts toward the latch, and a Stop is not counted as absence.

`syncExchange` and `pullRequest` parse the client's answer with `.allocate = .alloc_always`. The manifest's paths and hashes are read after the response buffer is freed, and `parseFromSlice`'s default hands back escape-free strings as slices into that buffer. Before this, a cast-time pull's diff compared freed bytes.

## Concurrency & lifecycle

- One in-flight turn per conversation. `tryBeginTurn` claims the slot (so `postMessage` can answer `409` before persisting anything); `spawnTurn` fires the turn on a raw detached thread and owns releasing the slot on every completion path.
- The turn runs off the httpz worker thread and writes frames to `events.jsonl` as it goes, so the client streams live via `/events` instead of blocking on one long response.
- Raw-thread sleeps (`sleepMsRaw`, Win32 `Sleep` on Windows) because `io.sleep` throws on a non-Io thread and a swallowed error would busy-spin a core.

## Dependencies

- `worker/tools` — the tool surface the loop calls (write/read/edit/search/shell/…)
- `worker/llm` — the model call machinery (streaming completions), and the per-turn retry budget the turn arms
- `worker/chat/overlay` — the recall overlay rendered around each chat call
- `config/cf_oauth` — the Cloudflare login, including the re-resolved token a retry hands over
- `worker/chat/context` — the recency window + pinned goal + rolling summary + digest ledger that keep the prompt bounded at any conversation length, and the capacity-scaled budgets the `ContextPlan` is built from
- `worker/continuity` — durable resume anchors: press on a cut, read at assembly, clear on a clean finish
- `worker/chat/plan` — task decomposition into routed subtasks the drive loop walks
- `worker/deploy/service` — casting a hive for the conversation from inside a turn
- `worker/oscillation`, `gateway/http` (App)

## Usage Context

Entered only through `chat_service.postMessage`. ON by default; the kill switch `VEIL_CHAT_BACKEND=0` returns `501`, which a client treats as a signal to fall back to a local engine. Open to every authenticated user. The per-role gating this note used to anticipate has landed: `tools.execute` refuses on `ctx.caps == .sandboxed` as its first statement, before any tool-specific logic, so there is exactly one place a capability decision is made. Non-admins run `.sandboxed`, admins `.full`, and the turn's advertised tool schema is trimmed to match — a sandboxed caller is never offered a tool that could only come back as a refusal. That includes the `cf_` belt a connected account adds: `buildTurnTools` projects it through the same allowlist (`CF_TOOLS_SANDBOXED`, empty today), and a test checks every name on a sandboxed belt against the gate. Scheduled tasks (`sched.zig`) enter the same `tryBeginTurn` + `spawnTurn` path, so a scheduled run is a real conversation.

---

*Case file grounded in the module's `//!` header and public API.*
