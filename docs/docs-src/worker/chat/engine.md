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

## Concurrency & lifecycle

- One in-flight turn per conversation. `tryBeginTurn` claims the slot (so `postMessage` can answer `409` before persisting anything); `spawnTurn` fires the turn on a raw detached thread and owns releasing the slot on every completion path.
- The turn runs off the httpz worker thread and writes frames to `events.jsonl` as it goes, so the client streams live via `/events` instead of blocking on one long response.
- Raw-thread sleeps (`sleepMsRaw`, Win32 `Sleep` on Windows) because `io.sleep` throws on a non-Io thread and a swallowed error would busy-spin a core.

## Dependencies

- `worker/tools` — the tool surface the loop calls (write/read/edit/search/shell/…)
- `worker/llm` — the model call machinery (streaming completions)
- `worker/chat/context` — the recency window + pinned goal + rolling summary that keeps the prompt bounded
- `worker/chat/plan` — task decomposition into routed subtasks the drive loop walks
- `worker/deploy/service` — casting a hive for the conversation from inside a turn
- `worker/oscillation`, `gateway/http` (App)

## Usage Context

Entered only through `chat_service.postMessage`. ON by default; the kill switch `VEIL_CHAT_BACKEND=0` returns `501`, which a client treats as a signal to fall back to a local engine. Open to every authenticated user. The per-role gating this note used to anticipate has landed: `tools.execute` refuses on `ctx.caps == .sandboxed` as its first statement, before any tool-specific logic, so there is exactly one place a capability decision is made. Non-admins run `.sandboxed`, admins `.full`, and the turn's advertised tool schema is trimmed to match — a sandboxed caller is never offered a tool that could only come back as a refusal. Scheduled tasks (`sched.zig`) enter the same `tryBeginTurn` + `spawnTurn` path, so a scheduled run is a real conversation.

---

*Case file grounded in the module's `//!` header and public API.*
