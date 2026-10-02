# tot

**File:** `src/cli/tot.zig`  
**Module:** `cli`  
**Description:** `veil --tater` — the terminal door to tater-tots: list them, deploy one, talk to it, follow it, change its settings, read and write the shared scratchpad, delete it.

---

## Purpose Summary

Every verb is one call to the local server (`config/cf_tot.zig`), which relays to the runtime in the user's Cloudflare account. Nothing here talks to Cloudflare. The replies are read with `std.json` into small structs that ignore unknown fields, so a newer runtime's extra fields do not break an older CLI.

## Key Exports

- `cmd` — the dispatcher for `veil --tater [ls | deploy | tell | watch | set | pad | rm | teardown]`
- `rosterLine` — one roster row: name, state, minds, model calls today, the local grant, the goal and its counters (pure, tested)
- `eventLine` — one event as a terminal line (pure, tested)

## Dependencies

- `../cli.zig` — `Ctx`, `call` (the authenticated request), `flagVal`, `jstr`, `appendStr`, `appendNum`, `out`
- `../worker/browser/util.zig` — `sleepMs`, the OS sleep `watch` uses between polls

## Usage Context

`cli.zig` dispatches `--tater` (and `tater`, and `tot`, its earlier name) here and lists them in `isCommand`; the help text has a TATER-TOTS section. `deploy` sends only the fields the server's `CreateReq` names (the server's request parser is strict). `--local` is the terminal form of the deploy form's checkbox: it lets the tater-tot queue jobs for the veil on this machine, and it exists only on `deploy`.

## Notable Implementation Details

- `watch` polls the event tail every 3 s from the newest sequence number it has printed; after the first reply, twenty failed polls in a row end it.
- `pad --clear` empties the scratchpad (the server keeps a local copy); `rm` says when the tater-tot was the last one and its Worker was removed with it.
- `--calls unlimited` (or `infinite`, `none`, `0`) is no limit on model calls; `--pace` takes 5 seconds and up. The roster ends with the tools the account's tater-tots have.
- `key brave <key>` (or `google`, `google_cx`) gives the tater-tots a search API key; `--remove` takes it away.
- `teardown` needs `--yes`: it removes the runtime, every tater-tot and everything they stored from the account.
- `tell` joins its remaining arguments into one text, so `veil --tater tell Gary /goal map every harbour --forever` needs no quotes.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
