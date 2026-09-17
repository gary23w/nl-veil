# overlay

**File:** `src/worker/chat/overlay.zig`
**Module:** `worker/chat`
**Description:** The recall overlay — a per-turn working field of the conversation's memory, settled by spreading activation around what the model is doing **right now**, rendered as one advisory block before every round's chat-model call and removed the instant the model has answered.

---

## Purpose Summary

Recall used to happen at two seams of a turn: once at the start, keyed on the goal, and once per synthetic drive step, keyed on the step text. The reasoning rounds in between — the tool calls, the readings, the decisions, where a long turn actually lives — saw the blocks assembled at turn start and nothing else. Once the working span was compacted, a finding survived only in neuron-db, which nothing consulted until the next drive step, and the model re-did the work. Observed on a long research-and-write turn: three compactions, the site conventions re-read after each one.

The overlay reuses the swarm's in-process activation field ([hyperspace](#doc=worker/hyperspace)), which the chat engine had never used, and drives it per **thought** instead of per turn.

## The four moments

| moment | what happens | subprocesses |
|---|---|---|
| turn start | the field is seeded: the conversation's own partition (one wide associative pull around the goal), the durable memory's lines exactly as the prompt shows them (credential values already masked; the YOUR MEMORY header and the withheld-credentials footer are framing, not facts, and stay out), the file ledger | 1 |
| every finding | the note the engine mints for the store enters the field the moment it exists — recallable in the very next round, compaction or not. A full field evicts a fact a settle has already measured before a finding that has not been through one, so a round's findings all survive to the next render unless that one round outnumbers the field itself | 0 |
| every round's chat-model call (not the auxiliary verdict, compaction or planning calls) | the field settles around the live **cue** — goal, last narration, last tool call, last result head, recently fired lines — and the block is appended as the LAST message of that request only, then removed | 0 |
| turn end | every fired store-backed line is strengthened in the store, so a fact that helped ranks higher next time | ≤ 8 |

## Advisory by construction

The block says the lines are recollections, not instructions, and the engine behaves that way:

- **Refractory rule.** A line offered `REFRACTORY` (3) renders in a row that the model never picked up is inhibited for `INHIBIT` (4) renders. The overlay rotates what it offers instead of insisting — the model's choice to ignore a memory is respected mechanically.
- **Firing.** A line whose distinctive stems appear in the model's next narration or tool call has been used: its streak resets, it is un-inhibited, its text joins the hot tail of the next cue (the link that carries value from one firing to the next), and it is queued for strengthening. *Distinctive* means rare in the field (a stem few facts carry, `RARE_DF`) or at least `FIRE_MIN` shared stems, so a task's common vocabulary cannot fire everything at once.

## Why it cannot loop

- A rendering is never fed to the field, the store or the cue: the field cannot recall its own output. A thought is a cue, never a fact — only engine-observed findings enter.
- The cue is built from engine-held strings, never from the working context, so one block cannot seed the next.
- Every render is bounded by fixed numbers (field cap, settle passes, byte budget, fired and strengthened caps) and spends zero subprocesses — a test pins that count.
- Inhibition can only remove lines. Nothing here can grow the transcript or the store on its own; the block is removed from the working context before anything else is appended, so it is never compacted, summarized, observed, or re-uploaded.

## Provenance without pollution

Each line carries a source tag — `[conv]`, `[durable]`, `[ledger]`, `[found]`, `[anchor]` — rendered beside it and kept out of its stems. List dressing and short leading brackets (`[fact]`, `[chat r0]`) are stripped before a line enters the field, otherwise "fact" or "chat" would be the best-connected hub and every memory would fuse.

## Knobs

`NL_MEM_OVERLAY=0` disables the overlay for a turn; `NL_MEM_OVERLAY_BYTES` sizes the rendered lines (default 900); `NL_HYPERSPACE_CAP` sizes the field (default 256 here, shared with the swarm's setting). The turn's accounting — renders, lines shown, fired, inhibited, strengthened — is logged under the `chatmem` scope at turn end.
