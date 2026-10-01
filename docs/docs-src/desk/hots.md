# hots

**File:** `desk/src/hots.zig`  
**Module:** `desk`  
**Description:** The desk's picture of the user's hots: fixed-size roster rows, the event tail and the shared scratchpad, the readers that fill them from the server's JSON, and the writer for a deployment's request body. No I/O.

---

## Purpose Summary

The Hots tab (drawn in `main.zig`) shows up to three hots, the selected one's console and the scratchpad they share. This file is the data under it. The poller calls the readers and publishes the results into the Store under its one lock; the UI copies them out and draws. A hot's events are kept as `Ev`: the swarm console's colour key, the event's own kind, the goal iteration it belongs to and its text with its line breaks, which the tab's console wraps and scrolls.

## Key Exports

- `Row`, `PadRow`, `Roster`, `Ev` — the fixed-size values the Store holds; a row carries the hot's local `folder` (Open folder), an event its kind, iteration and up to 2200 characters of text with its line breaks (a longer one ends in "...", and the local `events.log` has it whole)
- `parseRoster` — a `GET /api/v1/hots` reply into a `Roster`; anything that is not that reply leaves the output untouched
- `parseHot` — the one row a deploy / command / settings reply carries
- `appendEvents` — the events newer than the last sequence held, appended to the tail; the oldest rows drop when it is full
- `parsePad` — the newest `MAX_PAD` scratchpad entries, oldest first
- `Form`, `deployBody` — the deploy form as the server's `POST /api/v1/hots` reads it
- `textBody` — `{"text": ...}` for a command or a scratchpad entry

## Dependencies

- `std` only: no I/O, no other desk module

## Usage Context

`store.zig` holds a `Roster`, the selected hot's events and the scratchpad rows. `poller.zig` fills them (`refreshHots`, `refreshHotEvents`, `refreshHotPad`) only while the Hots tab is on screen: the tab raises `Store.hots_watch` every frame and the poller lowers it every tick, because each poll is a call into the user's Cloudflare account. `main.zig` draws the tab (`drawHots`, `drawHotForm`, `drawHotPanel`) and builds the deploy body with `deployBody`.

## Notable Implementation Details

- Names, states and the goal line are stored as one line (line breaks and tabs become spaces); event and scratchpad text keep their line breaks, because the tab wraps them (`hotWrapNext` in main.zig). Every cut lands on a UTF-8 boundary.
- The bodies are written by `std.json`, and a test reads one back through a strict parser: text inside a goal cannot add a field, so it cannot grant the owner's machine.
- Event kinds borrow the swarm console's colours by meaning: an improving verdict reads as a score, an error as a stop, a human's message as a tick.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
