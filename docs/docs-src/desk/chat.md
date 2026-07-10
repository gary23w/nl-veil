# chat

**File:** `desk/src/chat.zig`  
**Module:** `desk`  
**Description:** The chat worker thread and "brain" of the veil-desk native app — it runs the Chat tab's model turns, the tool/shell agentic loop, swarm casting and orchestration, the full-auto loop, and the neuron-db-backed memory/playbook/learning harness.

---

## Purpose Summary

chat.zig is the third worker thread of veil-desk (beside the UI and the poller), owning its own std.Io and communicating with the UI only through a locked Store. It runs the Chat tab's entire "brain": it streams model completions, parses and dispatches tool/shell/cast actions with heavy multi-dialect recovery, watches and orchestrates hive swarms, drives a full-auto continuation loop, and maintains a layered neuron-db learning system (durable user memory, an operational playbook of verified fixes, procedural skills, a user model, and a background judge/curator). It also owns all chat-side persistence (conversation JSONL, settings, sealed key) and an async micro-console for running shell commands off the worker's blocking path.

## Key Exports

- `Chat` (struct) — the whole chat engine: state fields + all methods; instantiated once and `run()` on its own thread
- `Chat.run` — the ~10Hz tick loop: drains UI commands, pumps the stream, polls the console, and staggers watchCast/maybeLoop/maybeVeilWork/maybeFinishAfterVeil/pumpJudge/curateOnce
- `Chat.cmdSend` — entry for a user message: resets per-turn/loop/arc budgets, bumps conv_epoch, arms auto-loop, fast-paths explicit cast commands, else startTurn(.user)
- `Chat.pumpStream` — polls the live llm.Stream and, on completion, runs the central settle dispatcher (tool/shell/cast/reflect/collect/answer + recovery + learning + verify + loop)
- `Chat.fireCast` — POSTs /api/v1/cast via netcli, builds in the conversation dir, and starts concurrent-veil orchestration
- `Chat.watchCast` — tails a running cast's events.jsonl (~1Hz), narrates milestones, enforces the desktop deadline, and triggers collect on stop
- `Chat.cmdNewConv` / `Chat.cmdStopCast` / `Chat.appendMsg` — conversation lifecycle + message persistence primitives
- `Turn` (module-internal enum) — the turn state machine: idle, user, collect, tool_follow, reflect, loop_infer, consolidate
- `CastSpec` / `ToolCall` / `Proposal` — parsed-config value types
- `buildTrace`, `parseProposal`, `toolCall`/`toolCallXml`/`toolCallLoose`, `stripToolTail`, `runCall`, `userWantsCast`, `userWantsKill`, `castSpecFromUser`, `announcesAction`, `rowRefeeds` — pure parsing/classification helpers

## Dependencies

- store.zig (Store — the lock-guarded shared UI/state surface; all cross-thread reads/writes go through it)
- llm.zig (Stream + start/poll/finish/abort, Provider, jsonUnescape — the model call machinery)
- netcli.zig (in-process server calls: cast + chatTool to POST /api/v1/cast and /api/v1/chat/tool)
- scan.zig (filesystem-first cast watching: tailEvents/tailEventsFrom, listSwarms, listWorkFiles, readWorkFile, writeStop/writeControl)
- neuron.zig (neurondb.Db — the hippocampus/playbook/skills/user-model/memory scopes; all ops no-op when the binary is absent)
- httpc.zig (in-process loopback HTTP to probe local Ollama /api/tags and /api/ps — avoids spawning curl)
- catalog.zig (BYOK provider table + base resolution), secrets.zig (sealed API key), log.zig, std.Io, builtin

## Usage Context

Instantiated once and launched on its own thread via Chat.run at app startup. The UI thread never calls its methods directly — it pushes typed commands into a Store queue (send, new/select/rename/delete conv, console_run/approve/deny, stop_cast, stop_turn, loop_kick, forget_mem, prop_accept/reject, save_settings/key) which drainCommands consumes each tick. Everything the user sees (streaming text/reasoning, cast activity rows, milestone narration, memory/proposal panes, metrics, console scrollback) is published back into the Store under lock. It talks to the running nl-veil server on :8787 for casting and shared tools, and to a local neuron-db binary for memory; both degrade gracefully (error notice / no-op) when unavailable.

## Notable Implementation Details

Concurrency: single worker thread, one `Turn` in flight, driven by a 100ms tick loop; heavy work (blocking netcli/neuron calls) runs on this thread but is invisible because it is not the UI thread. Shell commands are the exception — they MUST NOT run inline (a hang would wedge chat + cast-watching), so consoleStart spawns an independent OS process writing to two sink files (.out/.err — separate because Windows reopens inherited handles independently), and pumpConsole polls it via procExited (native non-blocking GetExitCodeProcess on Windows / waitpid WNOHANG on POSIX; note the u32 exit code preserves NTSTATUS crash codes that Child.wait's u8 Term would truncate). Guards: 60s(AI)/300s(You) deadline, Stop, 4MB flood cap. AI shell commands are parked behind an Approve/Bypass/Deny gate.

Fixed buffers, no per-turn heap for state: last_user[1600], reflect_draft[12288], build_dir[400], pending_directive[3600], cast_bp[1536], scratch event/file/swarm arrays, etc. Tool args are HEAP-duped off self.stream.content before the stream is freed (strict UAF discipline) because write_file/edit_file args can be a whole source file.

The settle dispatcher in pumpStream is the load-bearing state machine, with a precise precedence chain and extensive weak/local-model recovery: strict `TOOL:` line → `<tool:NAME>{...}</tool:NAME>` XML → nested-XML → loose recovery from the hidden reasoning channel (with a kill_swarm veto unless the user asked) → JSON-inferred → pasted code-block-to-write_file synthesis; plus a truncated-write chunked-append rescue and an empty/pathless-args rescue. Then RUN: shell, kill recovery, unknown-tool-dialect format nudge, an act-follow-through nudge (≤2/arc, for replies that announce but don't act), the reflect self-critique loop, the collect answer path, the concurrent-veil "do it yourself" nudge, cast dispatch, cast recovery, and finally plain answer — followed by Hebbian strengthen, an optional verify-before-done turn, memory consolidation, and maybeLoop.

conv_epoch is the cancellation barrier: bumped on send/new/switch/Stop; deferred continuations capture cast_epoch/turn_epoch and refuse to mutate a conversation that has moved on (a finished cast then leaves a passive note rather than hijacking a turn — unless it's still the same conversation, in which case it re-stamps and collects so the auto-loop keeps feeding).

Casting: chat casts build IN the conversation dir (_chat/builds/{conv}), so the run-dir basename is the conv id, not the hex. watchCast is size-guarded (skip re-parse when events.jsonl hasn't grown) and stale-run-guarded (a reused dir's prior-run log is folded from EOF). Concurrent Veil (CONCURRENT_VEIL): while the hive runs, the veil orchestrates the SAME shared dir (maybeVeilWork feeds it the hive's .blueprint + a narrate/steer/gap-fill brief and a layout guard against rival top-level structures), and maybeFinishAfterVeil composes a .collect answer from the single tree — deliberately no compare/merge step (the swarm's own micro-VCS reconciles concurrent edits). STEER: lines write the run's control bus.

Learning harness (all neuron-db, all no-op if disabled): distinct scopes — per-conversation convScope (hippocampus, recalled + auto-observed on every message), MEMORY_SCOPE (durable per-user keys/prefs, mirrored from personal `observe`), PLAYBOOK_SCOPE (operational lessons), SKILLS_SCOPE, USER_SCOPE, plus quarantine "-proposed" variants. Playbook lessons are minted DETERMINISTICALLY in pumpConsole only from a real fail(nonzero exit/timeout)→fix transition in the same arc (never model self-report), carry the salient error line as a failure signature, and are strengthen-only (Hebbian, keyed on the recalled lesson text, never the user prompt, to avoid the historic prompt-as-lesson poisoning). A background judge (pumpJudge, own stream + side dir + preferably a different model) grades the conversation JSONL trace (buildTrace surfaces USER/CLAIM/RESULT rows; only bracketed RESULT rows with real exit codes are ground truth) and proposes lessons/skills/user-facts into quarantine for human accept/reject in the Memory pane — it never writes a live scope or the conversation. curateOnce does once-per-session staleness/size/near-duplicate governance with archive-before-forget.

Auto-loop has three tiers: off, chat_loop (armed by every user send), and chat_loop_afk (double-click; never self-terminates — every automatic stop resets its budgets instead, only the user ends it). A .loop_infer turn writes the next user message; loopContinue stops on DONE/empty/near-repeat/cap unless afk. Arc flags (arc_acted/arc_mutated/arc_built/verify_done/act_nudges) implement the agentic floor: announced-but-unperformed follow-through, verify-before-done, and a one-shot terminal whole-build completeness check (fireTerminalVerify hands the model an engine-listed ground-truth file tree). The reflect loop iteratively self-critiques a HIDDEN draft and reveals the final answer once with a collapsed reasoning trace (no visible draft churn).

---

*Documentation generated for nl-veil — desk/chat.zig source analysis.*
