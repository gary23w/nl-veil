# commons

**File:** `src/worker/commons.zig`  
**Module:** `worker`  
**Description:** The swarm's shared message bus (messages.jsonl) + event-sourced task board (tasks.jsonl), kept byte-compatible with the Python Commons so the existing swarm-chat pane and board render identically.

---

## Purpose Summary

Not generic utilities — this is the swarm's coordination substrate: two append-only JSONL files under the run directory. `messages.jsonl` is the bus minds (and the veil/operator) post to and read their inbox from; `tasks.jsonl` is an event-sourced board where an `add` event opens a task and a `done` event closes it, folded into open/done counts. Minds in a swarm run sequentially in one worker process, so plain read+append is safe with no locking.

## Key Exports

- `sendMessage(gpa, io, run_dir, frm, to, text, round)` — append one bus line `{"i":N,"round":R,"from":…,"to":…,"kind":"msg","text":…}`; empty `to` becomes `"all"`
- `inbox(gpa, io, run_dir, me, limit)` — the recent messages addressed to `me` (or broadcast), excluding its own, as a newline-joined `from: text` block for injection into the moment prompt (caller frees)
- `addTask(gpa, io, run_dir, by, assignee, task)` → id — append a `{"type":"add","id":N,…}` event; the id is the count of prior add events
- `completeTask(gpa, io, run_dir, id, by, result)` — append the matching `{"type":"done","id":N,…}` event
- `Board { done, open }` + `board(gpa, io, run_dir)` — fold the task events into done/open counts (a done closes a prior add)

## Dependencies

- `worker/llm` — only for `jstr`, the JSON string escaper used to build the lines
- `std` — file I/O via `std.Io`

## Usage Context

The `send_message` / `add_task` / `complete_task` tool handlers in `tools.zig` call straight through here. `run.zig` posts operator and veil messages onto the bus, reads each mind's `inbox` into its moment prompt, and reads `board` counts; `agi.zig` broadcasts veil messages to all minds the same way.

## Notable Implementation Details

- Byte-compatibility with the Python Commons is a stated design constraint: the existing swarm-chat pane (`mind_msg`) and board must render identically, so line shapes are built by hand rather than via a serializer.
- "Append" is implemented as read-whole-file + concatenate + rewrite — acceptable exactly because minds run sequentially in one worker process (the header calls this out).
- Task ids are derived, not stored: `nextTaskId` counts `"type":"add"` lines, so ids are stable as long as the file only grows.
- Everything is best-effort and non-throwing: allocation or I/O failure degrades to a no-op / empty result rather than an error, and file reads are capped at 16 MB.

---

*Case file grounded in the module's `//!` header and public API.*
