# tot

**File:** `src/cli/tot.zig`  
**Module:** `cli`  
**Description:** `veil --tater` — the terminal door to tater-tots: list them, deploy one, talk to it, follow it, change its settings, set what it guards, verify a run's evidence chain, launch Agent Garrett, read and write the shared scratchpad, delete it.

---

## Purpose Summary

Every verb is one call to the local server (`config/cf_tot.zig`), which relays to the runtime in the user's Cloudflare account. Nothing here talks to Cloudflare. The replies are read with `std.json` into small structs that ignore unknown fields, so a newer runtime's extra fields do not break an older CLI.

## Key Exports

- `cmd` — the dispatcher for `veil --tater [ls | deploy | tell | watch | set | guard | verify | garrett | pad | limit | key | rm | teardown]`
- `rosterLine` — one roster row: name, state, minds, model calls today, the local grant, `DEFEND` when the posture is, `guard N` (and `TRIPPED`) when it watches anything, the goal and its counters (pure, tested)
- `eventLine` — one event as a terminal line (pure, tested)
- `chainHash` / `Chain` / `ChainEvent` — the runtime's evidence chain recomputed here: SHA-256 of `<prev>\n<seq>\n<t>\n<kind>\n<text>`, and a walker that takes a run's rows oldest first, counts unsigned rows (an older runtime's), and names the first row that was altered or does not follow the signed row before it (pure; held to the same vectors as `cloud/tot.test.mjs`)
- `guardCommand` — the words after the name as the tot's own `/guard` line, a phrase with spaces quoted again (pure, tested)

## Dependencies

- `../cli.zig` — `Ctx`, `call` (the authenticated request), `flagVal`, `jstr`, `appendStr`, `appendNum`, `out`
- `../worker/browser/util.zig` — `sleepMs`, the OS sleep `watch` uses between polls

## Usage Context

`cli.zig` dispatches `--tater` (and `tater`, and `tot`, its earlier name) here and lists them in `isCommand`; the help text has a TATER-TOTS section. `deploy` sends only the fields the server's `CreateReq` names (the server's request parser is strict). `--local` is the terminal form of the deploy form's checkbox: it lets the tater-tot queue jobs for the veil on this machine, and it exists only on `deploy`.

## Notable Implementation Details

- `watch` polls the event tail every 3 s from the newest sequence number it has printed; after the first reply, twenty failed polls in a row end it.
- `pad --clear` empties the scratchpad (the server keeps a local copy); `rm` says when the tater-tot was the last one and its Worker was removed with it.
- `--calls unlimited` (or `infinite`, `none`, `0`) is no limit on model calls; `--pace` takes 5 seconds and up. The roster ends with the tools the account's tater-tots have.
- `limit [N]` shows or sets how many tater-tots the account may run (24 by default, 1 to 1000); the roster ends with the count against it.
- `key brave <key>` (or `google`, `google_cx`) gives the tater-tots a search API key; `--remove` takes it away.
- `teardown` needs `--yes`: it removes the runtime, every tater-tot and everything they stored from the account.
- `tell` joins its remaining arguments into one text, so `veil --tater tell Gary /goal map every harbour --forever` needs no quotes.
- `guard <name> ...` sends the tater-tot its own `/guard` command: `add <https://...> [--text "..."] [--status N] [--every S] [--pin]`, `add dns:<host> [--type A]`, `rm <target|#n>`, `clear`, or nothing to list what it watches and the state of each target. The reply is the runtime's.
- `verify <run>` pages `GET /api/v1/tots/runs/:run/events?forward=1` from the run's first event and recomputes the chain on this machine. It exits 0 with the signed count and the last hash, 2 with the event where the chain broke and why, 1 when the run has no events or none of them is signed (a run from before the chain).
- `garrett` shows Agent Garrett as the server knows it; `garrett launch` puts it in the account beside the tater-tots (up to a few minutes: the modules come from the agent's repo, the upload is five calls); `garrett password` prints the password locking its chat UI; `garrett rm` removes it.
- `set` and `deploy` take `--posture defend|normal` and `--leash SECONDS|off`; `key alert <https://...>` is the guard's webhook, `key garrett_url` + `key garrett_token` point at an Agent Garrett deployed by hand.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
