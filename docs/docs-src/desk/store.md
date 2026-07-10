# store

**File:** `desk/src/store.zig`  
**Module:** `desk`  
**Description:** The single mutable source of truth shared across veil-desk's threads — a `Store` struct of fixed-size records and ring buffers, guarded by one custom spinlock, that lets the raylib UI thread read machine state without ever blocking on IO.

---

## Purpose Summary

store.zig defines `Store`, the one shared-state object the whole native app (Zig + raylib) reads and writes across threads. The UI thread (raylib draw + input) copies what it needs under lock and never touches IO; the poller thread (filesystem + net) and the chat thread write under lock and never touch raylib. A hard rule keeps raylib single-threaded while everything else observes state off-thread. It is pure state plumbing — data structures, constants, three command/notification rings, and a handful of push/pop helpers; no drawing, IO, or model logic lives here.

## Key Exports

- `Store` — the mutex-guarded shared struct holding server/fleet status, swarm roster + selected-swarm detail, settings, chat conversations/messages/streaming buffers, casts, consoles, memory, proposals, metrics, and the three thread rings
- `Store.pushCmd`/`popCmd` — UI→poller command ring (CMD_RING=32), drop-silently-when-full
- `Store.pushChatCmd`/`popChatCmd` — UI→chat-thread command ring (CHAT_CMD_RING=8), same drop discipline
- `Store.pushNotif` — poller→UI notification ring (NOTIF_RING=8), overwrites oldest when full; also fed to the OS tray
- `Store.pushMetric` — append a per-turn `TurnMetric` to the 60-slot performance ring for the chat Metrics tab
- `Store.consoleAppend` — append to the You/Veil shell scrollback, compacting to newest ~half on overflow
- `Store.lock`/`unlock` — take/release the internal spinlock around a manual critical section
- `mkCmd`/`mkChatCmd` — free functions that pack (kind,id,text) slices into a fixed-size `Command`/`ChatCommand` value
- Record types: `Command`, `ChatCommand`, `Notif`, `Settings`, `TurnMetric`, `OllamaModel`, `ChatMsg`, `ConvRow`, `CastRow`, `MemRow`, `PropRow`; enums `Tab`, `CmdKind`, `ChatCmdKind`, `ChatRole`, `CastStatus`

## Dependencies

- scan.zig — supplies SwarmSummary, Ev, Metrics, FileRow, SwarmConfig and the MAX_SWARMS/MAX_LOG/MAX_FILES caps embedded directly as Store fields
- log.zig — every push/pop helper emits log.trace breadcrumbs
- secrets.zig (referenced by contract) — Settings.chat_key is in-memory only, persisted through secrets.zig, never plaintext
- tray.zig (consumer) — Notif records are handed to the OS tray as well as shown in-app
- neuron-db (integration seam) — MemRow facts and PropRow proposals are the display mirror of the chat's local neuron-db hippocampus (memories.jsonl + quarantine '-proposed' scopes)

## Usage Context

Instantiated once and shared by pointer among the three long-lived threads of veil-desk. The raylib UI thread renders every field and enqueues user intent via pushCmd/pushChatCmd (Send, select swarm, save settings, approve a shell command, etc.). The poller thread (~1Hz) drains the command ring, rescans the data dir through scan.zig, and writes server/fleet/roster/selected-swarm state plus raises notifications. The chat thread owns conversation history on disk and streams the in-flight reply, reasoning, casts, console output, metrics, memory, and judge proposals back into the Store for the UI to draw. Nothing outside these push/pop helpers should mutate Store fields without holding the lock.

## Notable Implementation Details

Concurrency: all cross-thread state sits behind one custom `SpinLock` (atomic bool swap with .acquire/.release + spinLoopHint), NOT std.Thread.Mutex — that primitive is gone in this Zig and std.Io.Mutex needs an io handle the UI thread doesn't carry. It's justified by microscopic critical sections (copying small fixed arrays) and trivial contention (poller ~1Hz vs UI 60fps). Zero cross-thread allocation: every record is a fixed byte array + a `_len` field with a slice accessor (e.g. `idStr`), copied by value into rings. Three rings with two different full-policies: the two command rings (cmds head/tail, chat_cmds head/tail) DROP silently when full (a lost duplicate say/refresh is harmless); the notif ring OVERWRITES the oldest via head+count. The metric ring uses `turn_metric_count % METRIC_RING` and the count intentionally exceeds the 60-slot ring (iterate with @min). consoleAppend compacts to the newest half via copyForwards when the 16KB scrollback overflows. Load-bearing constant: STREAM_CAP=16384 carries an explicit crash scar — a hardcoded 8192 copy in drawChat crashed with 'index out of bounds: index 8194, len 8192' the first time a streamed reply crossed 8KB, so any UI-side snapshot buffer MUST reuse this constant. ChatMsg.text is 12288 (grew from 3K after LLM answers with reasoning/tables clipped). Semantic gotcha: ChatRole.thought (persisted as "r":3) is the veil's reasoning trace — rendered collapsed and EXCLUDED from prompt history so the model never re-reads its own reasoning as answer text; stream_draft marks pre-final content the UI must render as thinking, never as a delivered answer. Settings encodes the whole chat-provider matrix (chat_kind 0 local Ollama / 1 BYOK catalog / 2 custom URL), the persistent shell-approval bypass shell_always_allow ('Bypass' chosen once → future veil RUN: commands skip the approval prompt), and speed_mode (default ON = chat builds with its own file tools + 2-min research casts; OFF = long set-and-forget hivemind deploys). The per-command approval gate itself lives on the Store, not Settings — console_pending + console_pending_cmd park a pending veil RUN: command awaiting Approve/Deny, and the choice rides back as a console_approve/console_deny ChatCommand. chat_loop/chat_loop_afk are runtime-only and encode a three-tier autonomy toggle where AFK never lets the loop back itself out.

---

*Documentation generated for nl-veil — desk/store.zig source analysis.*
