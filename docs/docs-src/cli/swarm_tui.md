# swarm_tui

**File:** `src/cli/swarm_tui.zig`  
**Module:** `cli`  
**Description:** `veil --swarm "<goal>"` — cast a swarm and watch it work from the terminal, with one chat line into the whole hive.

---

## Purpose Summary

A terminal view of a live swarm. The right side is one panel per mind (name, role from the cast plan, the tool it is on, its last result) that flashes when a new act lands, with the files the swarm has touched underneath; the left side is the broker chat, where a typed line goes to the swarm's one voice (control op `veil`, which answers in first person and hands the instruction to every mind) and the swarm's replies, mind-to-operator messages, goal changes and completion arrive as lines. Nothing is configured: roster, roles and files come from the event stream. The swarm needs no human; the view leaves when the run's `stopped` event lands.

## Key Exports

- `cmd(ctx, args)` — the verb: parses the goal and flags (`--minds`, `--minutes`, `--model`, `--provider`, `--lineage`, `--once`), POSTs `/api/v1/cast` (continuous unless `--once`), then runs the loop: poll `/api/v1/swarms/:id/events` every 500 ms, drain keys, redraw on change, send `/stop`, `/goal`, `/say` and plain lines as control ops
- `Model` + `applyEvent(model, gpa, line, now_ms)` — the pure reducer over events.jsonl lines: `started` (roster, goal), the orchestrator's `cast_plan` act (roles), per-mind `act` rows (a step; the engine's context rows and its own passes are skipped), `tick`, `veil_msg` / `mind_msg`, `files` (objects by `path`), `score` / `cost` / `phase`, `goal` / `resumed`, `complete`, `stopped`
- `render(gpa, out, model, input, w, h, now_ms)` — one full frame of ANSI text for a `w`×`h` terminal, every row padded, the cursor placed on the input line; one column below 70 wide
- `Line` (the byte-at-a-time line editor: printable UTF-8, Backspace by codepoint, Enter submits, CSI sequences swallowed) and `classify(line)` (the `/stop` `/goal` `/say` `/quit` grammar; anything else speaks to the swarm)
- `visibleWidth(s)` — columns of a rendered row with its escape codes stripped

## Dependencies

`cli.zig` (`call`, `jsonStr`/`jsonNum`/`JsonObjs`, `jstr`, `flagVal`, `appendStr`/`appendNum`, `out`), `worker/browser/util.zig` (`sleepMs`). Raw mode via `SetConsoleMode` (Windows: VT input and output) or termios (POSIX); size via `GetConsoleScreenBufferInfo` or `TIOCGWINSZ`.

## Usage Context

Reached from `veil --swarm` and `veil swarm` (`cli.dispatch`; `--swarm` is in `isCommand` so `main.zig` routes it like any verb). Reads the same events endpoint the desk poller and `veil events --follow` read; writes the same control ops the desk's Swarm tab writes, plus `veil`, which nothing used before.

## Notable Implementation Details

- Keys arrive on a thread doing a blocking one-byte read into a small ring; the loop never blocks on input, so events keep flowing while the user types. When stdin ends (a pipe), a finished swarm leaves after 1.5 s instead of waiting for Enter.
- A redraw happens only when an event, a key or a resize changed something, or when a panel's 1.5 s flash expires — an idle swarm costs nothing.
- Operator messages are drained by the worker at round end, so a reply takes a round or two; the chat says so once.
- The tests feed a synthetic event stream through the reducer and render frames at 25×9 to 200×50, asserting every row fits (with codes stripped) and the right content shows; the live smoke is a real cast watched with stdin piped and frames captured.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
