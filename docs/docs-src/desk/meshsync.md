# meshsync

**File:** `desk/src/meshsync.zig`
**Module:** `desk`
**Description:** The desk's settings, shared with the user's other veils through their harness: which settings travel and under what names, how each is written as text and read back, and the decision made for each on a pass. No I/O.

---

## Purpose Summary

The harness keeps small named values for the whole account (see [cf_harness](../config/cf_harness.md), "Shared settings"). The last write of a name wins, and each value carries the time the harness took it. With this file the desk keeps its own settings level with them, so a second desk logged in to the same Cloudflare account takes the first one's choices, and a change made on either reaches the other.

**What travels** (15 names, all starting `desk.`): the chat model (provider kind, catalog provider, one-model-or-trio, base URL, model id, as one value), the thinking and prompting models of a split trio, the Cloudflare-default choice, Agent Garrett on or off, speed mode, where the chat's brain runs, fast reasoning, the tool map, Clef, the theme id, the dyslexia face, text size, bold, and the narrator.

**What stays on the machine:** the server target (port and host), the data folder, every key and token (they are in the operating system's secret store and are never written here), the shell-approval bypass, the browser-window choice and the pane sizes.

The poller runs a pass every 60 seconds while the server is online, the desk's settings have loaded and the switch (`Settings.mesh_sync`, the checkbox in the Tasks tab's Web harness view, on by default) is on. A pass reads `GET /api/v1/harness/settings`; when the login has no Cloudflare connection, or no harness of version 10 or newer answers, the pass ends there and nothing changes. For each name it then decides (`decide`):

- the harness holds a write newer than the one this desk last agreed on: the desk **takes** it. When both sides changed, the harness's wins, because it is the copy every other veil already took.
- otherwise, the desk's value differs from the agreed one, or nothing was ever agreed: the desk **gives** its value.

Taken values are written into the desk's settings, saved, and announced with one notification. A value this desk could not have written (a number out of range, an unknown theme id shape, a name that is not one of the 15) changes nothing. What the desk and the harness last agreed on is kept in `{data}/.veil-desk/mesh-sync.json`.

The provider is carried as the desk stores it: a catalog provider by its index in the desk's model catalog. Two desks on different versions whose catalogs differ can therefore disagree about which provider an index names.

## Key Exports

- `KEYS` — the 15 names
- `localValue` / `apply` — one setting as text, and text taken back into the settings (false, with nothing changed, when it is not valid)
- `decide` / `Action` — take, give or leave, from this desk's value, the agreed value and time, and the harness's value and time
- `Table` / `Entry`, `parse`, `write`, `giveBody` — the harness's answer and the sync file (one shape), and the body of a write

## Tests

Every name is written and read back to the same settings while machine-local ones stay put; values the desk could not have written change nothing; the decision table (first desk gives, second takes, a local change is given, the harness wins when both changed); and the parse, file and write-body shapes.
