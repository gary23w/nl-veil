# hot

**File:** `src/cli/hot.zig`  
**Module:** `cli`  
**Description:** `veil hot` — the terminal door to hots: list them, deploy one, talk to it, follow it, change its settings, read and write the shared scratchpad, delete it.

---

## Purpose Summary

Every verb is one call to the local server (`config/cf_hot.zig`), which relays to the runtime in the user's Cloudflare account. Nothing here talks to Cloudflare. The replies are read with `std.json` into small structs that ignore unknown fields, so a newer runtime's extra fields do not break an older CLI.

## Key Exports

- `cmd` — the dispatcher for `veil hot [ls | deploy | tell | watch | set | pad | rm | teardown]`
- `rosterLine` — one roster row: name, state, minds, model calls today, the local grant, the goal and its counters (pure, tested)
- `eventLine` — one event as a terminal line (pure, tested)

## Dependencies

- `../cli.zig` — `Ctx`, `call` (the authenticated request), `flagVal`, `jstr`, `appendStr`, `appendNum`, `out`
- `../worker/browser/util.zig` — `sleepMs`, the OS sleep `watch` uses between polls

## Usage Context

`cli.zig` dispatches the `hot` verb here and lists it in `isCommand`; the help text has a HOTS section. `deploy` sends only the fields the server's `CreateReq` names (the server's request parser is strict). `--local` is the terminal form of the deploy form's checkbox: it lets the hot queue jobs for the veil on this machine, and it exists only on `deploy`.

## Notable Implementation Details

- `watch` polls the event tail every 3 s from the newest sequence number it has printed; after the first reply, twenty failed polls in a row end it.
- `pad --clear` empties the scratchpad (the server keeps a local copy); `rm` says when the hot was the last one and its Worker was removed with it.
- `teardown` needs `--yes`: it removes the runtime, every hot and everything they stored from the account.
- `tell` joins its remaining arguments into one text, so `veil hot tell Gary /goal map every harbour --forever` needs no quotes.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
