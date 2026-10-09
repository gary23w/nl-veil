# tots

**File:** `desk/src/tots.zig`  
**Module:** `desk`  
**Description:** The desk's picture of the user's tater-tots: fixed-size roster rows, the event tail and the shared scratchpad, the readers that fill them from the server's JSON, and the writer for a deployment's request body. No I/O.

---

## Purpose Summary

The Tater-tots tab (drawn in `main.zig`) shows the account's tater-tots against its limit (`Roster.max`, from the server; `ROSTER_CAP` rows are held, `total` counts them all), the selected one's console and the scratchpad they share. This file is the data under it. The poller calls the readers and publishes the results into the Store under its one lock; the UI copies them out and draws. A tater-tot's events are kept as `Ev`: the swarm console's colour key, the event's own kind, the goal iteration it belongs to and its text with its line breaks, which the tab's console wraps and scrolls.

## Key Exports

- `RunRow`, `parseRuns`, `rowLeaf` — the runs list (`GET /api/v1/tots/runs`): every deployment kept on the server's machine, newest first; a live row names its run by the last segment of its folder
- `Row`, `PadRow`, `Roster`, `Ev` — the fixed-size values the Store holds; a row carries the tater-tot's local `folder` (Open folder), an event its kind, iteration and up to 2200 characters of text with its line breaks (a longer one ends in "...", and the local `events.log` has it whole)
- `parseRoster` — a `GET /api/v1/tots` reply into a `Roster`; anything that is not that reply leaves the output untouched
- `parseTot` — the one row a deploy / command / settings reply carries
- `appendEvents` — the events newer than the last sequence held, appended to the tail; the oldest rows drop when it is full
- `parsePad` — the newest `MAX_PAD` scratchpad entries, oldest first
- `Form`, `deployBody` — the deploy form as the server's `POST /api/v1/tots` reads it
- `textBody` — `{"text": ...}` for a command or a scratchpad entry

## Dependencies

- `std` only: no I/O, no other desk module

## Usage Context

`store.zig` holds a `Roster`, the selected tater-tot's events and the scratchpad rows. `poller.zig` fills them (`refreshTots`, `refreshTotEvents`, `refreshTotPad`) only while the Tater-tots tab is on screen: the tab raises `Store.tots_watch` every frame and the poller lowers it every tick, because each poll is a call into the user's Cloudflare account. `main.zig` draws the tab (`drawTots`, `drawTotForm`, `drawTotPanel`) and builds the deploy body with `deployBody`.

## Notable Implementation Details

- Names, states and the goal line are stored as one line (line breaks and tabs become spaces); event and scratchpad text keep their line breaks, because the tab wraps them (`totWrapNext` in main.zig). Every cut lands on a UTF-8 boundary.
- The bodies are written by `std.json`, and a test reads one back through a strict parser: text inside a goal cannot add a field, so it cannot grant the owner's machine.
- An event's `brief` is the runtime's one line for it (for a tool call: the tool, its first argument, the first line of its result); an older runtime sends none and the text's first line stands in. `ok` false marks a row that went wrong, whether the runtime said so or the line shows `-> ERROR` / `-> FAILED`. `hasMore` says whether opening the row shows more than the brief.
- Event kinds borrow the swarm console's colours by meaning: an improving verdict reads as a score, an error as a stop, a human's message as a tick. The guard's rows (`guard`, the first look at a target; `tripwire`, a change) read green when their outcome is `ok` (a target up, a recovery) and red otherwise (tripped, changed).

---

*Case file grounded in the module's `//!` header, public API, and its tests.*


## Runs

Past-run cards put the name, goal and timestamp on separate lines. A selected run wraps its goal and deployment error above the controls; the activity log reserves a separate header for its error filter. **Remove run** asks for a second click, removes the saved entry and clears its selected console. The files stay in the run folder and can be restored to history by removing `.hidden` there.

The Store selects a run, not just a name: `tot_sel` + `tot_sel_leaf` (+ `tot_sel_past`). The poller starts the console over (`tot_sel_gen`) when the selected name comes back as another run - deployed again after a delete - and keeps it when the same run goes from live to ended, reading the rest from the run's folder (`totRunEvents`). A failed deploy selects the failed run the server recorded.
