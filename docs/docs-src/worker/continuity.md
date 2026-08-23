# continuity

**File:** `src/worker/continuity.zig`  
**Module:** `worker`  
**Description:** Durable resume anchors — the half of "a cut unit of work resumes instead of restarting" that outlives the transcript. The chat engine already fuses a continuation state into the engine row it commits when it cuts a turn; this module presses the same text into neuron-db under a scope of its own, addressed to the WORK rather than to a transcript, so the next unit that picks that work up reads it even when it opens a different conversation.

---

## Purpose Summary

Four functions over the `Mem` the engine, the swarm and the tools already share — deliberately not a second memory system, so chat, sched and a swarm mind all resume through one implementation instead of three that drift.

The engine's fused engine row is enough for an ordinary conversation: it sits in `messages.jsonl` and `seedLines` replays it on the very next turn. It is enough for exactly as long as that row stays inside the recency window, and it is never enough for a surface whose next unit of work reads a *different* transcript than the one that was cut. A scheduled task is the sharp case — `sched.zig` hands every run a fresh `conv_dir`, so the next run's `assembleHistory` opens an empty `messages.jsonl` and a `context.json` that does not exist. The row the engine so carefully wrote is addressed to a transcript nobody will ever read, and a task that keeps hitting the spend ceiling restarts from zero every single run. No amount of care inside one transcript can fix that; this module is the fix.

## Key Exports

- `SCOPE_PREFIX = "resume:"` — the namespace for every anchor. A **prefix**, never a `__child` (see below).
- `Cut` (enum) — why the unit stopped: `.ceiling` · `.loop_guard` · `.window` · `.deadline` · `.operator`, each with `text()` completing the anchor's opening sentence. Only `.ceiling` and `.loop_guard` are wired today, from the engine's two cut paths.
- `scopeFor(buf, unit) []const u8` — `resume:{unit}` rendered into a caller buffer, no allocation. Empty when `unit` is empty or will not fit, and every entry point treats an empty scope as "this capability is off".
- `press(mem, unit, why, body)` — record where a unit of work stopped, **superseding** whatever the last cut left. `unit` is the caller's own memory scope (`ctx.scope` on every surface), so a conversation, a scheduled task and a swarm mind each anchor themselves without agreeing on any new addressing scheme first. A body under 24 trimmed bytes is dropped rather than pressed.
- `read(gpa, mem, unit, cap) []u8` — the anchor rendered for a prompt, or `""` when there is none. Caller frees.
- `clear(mem, unit)` — drop the anchor; the work finished, there is nothing to resume.
- Budgets: `PRESS_MAX_BYTES = 1400` · `READ_MAX_FACTS = 24` · `READ_CAP_BYTES = 1200`.

## Dependencies

Only `std` and `worker/oscillation` (`Mem`). No new store, no new binary, no new file on disk.

## Usage Context

The chat engine is the only caller today, at three points in `worker/chat/engine.zig`: `read` bids the anchor into the [prompt workspace](#doc=worker/chat/workspace) on the `continuation` channel at 0.75 — leading the varying channel, ahead of recall — while assembling the turn; `press` runs on the cut path beside the fused engine row, mapping the engine note to `.loop_guard` or `.ceiling`; and `clear` runs on every normal completion. Because it keys on `ctx.scope`, a [scheduled task](#doc=worker/sched) anchors under its stable `sched:{taskid}` scope and resumes across the fresh `conv_dir` each run gets. Swarm minds are surface-compatible but not wired yet.

## Notable Implementation Details

- **`readPage`, not `recall`/`assoc`.** Every other read of this store is a scoring contest keyed on a query, and that is precisely what fails here: at resume time there is no good query. "continue" retrieves nothing, and keying on the pinned goal returns six goal-shaped facts rather than the thread that was actually interrupted. `readPage` asks no question — this scope's facts, verbatim, insertion order, complete, one spawn. Deterministic where top-k is a lottery, which is the whole point of writing the state down.
- **The scope is a prefix, not a child.** `Mem.assocAcross` merges `<scope>__*` in a single spawn and runs live on the chat scope in two paths that work today, so `{scope}__resume` would silently start competing for slots inside both. `resume:{scope}` is invisible to `scopeFamilyBase` (which gates on a literal `"chat:"` head), to every assoc/recall call in the tree, and to `read_doc`'s enumeration. An anchor is reachable only by the one `readPage` that names it — that is what makes adding this safe.
- **`ANCHOR_HEAD` is load-bearing, and asserted.** `Mem.replace` forgets the scope *before* it observes, and `observe` drops a fact under 12 alphanumerics (`cleanFactInto`), so a body of mostly paths and punctuation would erase a perfectly good anchor and store nothing in its place — a silent lost resume. The fixed header clears that bar by itself, which is a test rather than a convention because the failure is invisible. It also makes the record self-describing: prose in a fact store has no schema.
- **Supersede, not append.** `press` uses `Mem.replace`, so cut #2 replaces cut #1 and fifty cuts leave exactly one anchor. The same discipline as `seedLines`' newest-row rule, made durable.
- **The read block is framed as a record, never an instruction**, and says in as many words that a request about something else should ignore it. A cut turn followed by an unrelated question is a real case; a continuation block that hijacked it would be a worse bug than the one this fixes. That framing is what makes it safe to inject unconditionally.
- **Invisible when healthy.** Every normal completion clears the scope, so an ordinary conversation reads an empty anchor, the workspace drops the empty text without registering a block, and the packed prompt and decision log are byte-identical to before.
- **Best-effort throughout.** `Mem.run` returns null on a missing binary, a non-exit term or a non-zero status, and every miss here degrades to a zero-length slice. A missing `neuron.exe`, a read-only db, an OOM: the anchor is simply not written or not found, and the caller behaves exactly as it does today. Nothing on any hot path may fail *because* a continuation could not be recorded.
- **No second inference.** The press banks the distillation the engine's handoff already paid for.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
