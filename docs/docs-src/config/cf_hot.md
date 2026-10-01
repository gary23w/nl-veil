# cf_hot

**File:** `src/config/cf_hot.zig`  
**Module:** `config`  
**Description:** Hots — autonomous technicians that run the veil's goal loop in the user's own Cloudflare account. This module uploads their runtime (`cloud/hot.js`) through the Cloudflare login, relays the desk's and the CLI's requests to it, and runs the jobs a hot is allowed to send to the owner's machine.

---

## Purpose Summary

A hot (Human Overview Technician) is the goal loop of `worker/chat/goal.zig` with no human in it and no machine of the user's under it. Each hot is a Durable Object in one Worker script, `veil-hots`, that this module uploads into the account behind "Log in with Cloudflare". An alarm is the hot's heartbeat: every alarm runs one iteration (pick, do, measure, record, learn), and its model calls go through the account's own AI binding. An account holds at most three hots and the first is always named Gary; the runtime enforces both, and a test here holds the two files to the same numbers.

After the upload this module is a relay. The desk's Hots tab and `veil hot` ask this server; this server asks the runtime with a bearer token only the two of them know. The token is derived, never stored: HMAC-SHA256 under the server key of the user, the account and a generation counter. The state file (`{data}/u{uid}/cf_hots.json`) holds the runtime's address, the hash of the uploaded script and the list of hots allowed onto this machine, and nothing a reader could use.

A hot deployed with `local` may queue jobs for the veil on the owner's machine. Nothing listens at home for them: a background thread polls each approved hot's queue every 20 s, runs a job as an unattended chat turn through the same entry points a scheduled task uses, and posts the turn's final answer back. The approval is a checkbox at deployment and is recorded in this server's state file, so a runtime that claimed the grant for itself would find no bridge.

## Key Exports

- `SCRIPT`, `MAX_HOTS`, `PRIMARY` — `"veil-hots"`, `3`, `"Gary"`
- `validName` — a hot's name: 1-24 of letters, digits, `-`, `_`, starting with a letter (it becomes a URL segment and part of a conversation id)
- `listHots` — `GET /api/v1/hots`: the roster as the runtime reports it, plus connected / deployed / reachable / current, the address, the local grants and the last deployment error
- `createHot` — `POST /api/v1/hots`: uploads the runtime when the account lacks it or runs another build's, then creates the hot; a `local: true` body records the grant
- `deleteHot` / `teardown` — `DELETE /api/v1/hots/:name` removes one hot, and when it was the last one the Worker script too (the answer says `worker_removed`); `DELETE /api/v1/hots` removes the script and everything every hot stored. Both forget the deployment, every grant to this machine and the token generation the script held
- `hotEvents` / `hotCommand` / `hotConfig` — the event tail, a command or message, and the settings (`model`, `pace_s`, `size`, `daily_calls`, `charter`, `paused`; never `local`)
- `padRead` / `padWrite` / `padClear` — the scratchpad the account's hots share; clearing it first keeps the local copy as `_hots/scratchpad-<when>.md`
- `hotFolder` — a deployment's local folder, `u<uid>/_hots/<name>-<YYYYMMDD-HHMMSS>` (UTC): one per run, so a hot deployed again under the same name never writes into the old one's
- `bgLoop` — the hots thread: every 20 s the owner's-machine bridge, every third pass the local folder mirror (and the replacement of a runtime an older veil uploaded)

## Dependencies

- `cf_oauth.zig` — `resolveToken` (the OAuth bearer and account id) and `apiCall`, the one Cloudflare transport: the bearer rides curl's stdin config, never a file
- `../gateway/http.zig` — `App` (`server_key`, `cf_api_root`, data dir), `requireUser`, the error helpers
- `../worker/chat/engine.zig` — `tryBeginTurn`, `spawnTurn`, `isTurnLive`, `liveTurnWithPrefix`: how a job becomes a chat turn
- `modelcfg` — the default Workers AI model
- `cloud/hot.js` — embedded as `hot.js` (build.zig) and uploaded as it is

## Usage Context

`main.zig` registers the nine routes, lists this file in its route-gate audit (`ROUTE_MODS`) and starts `bgLoop` beside the scheduler thread. The desk reaches the routes through `netcli.hots*` (poller.zig, only while the Hots tab is on screen); the CLI through `cli/hot.zig`. Every route is admin-gated like the scheduled tasks: a hot spends the account's Workers AI, and one with the owner's machine starts full-tool turns there.

## Notable Implementation Details

- Two scripts go up. `veil-hots-py` (cloud/hot_py.py, the `python_workers` flag, a `text/x-python` module) runs a hot's Python and has no public address; the runtime reaches it through a service binding, `PY`. The runtime's upload also asks for Cloudflare's browser binding, `BROWSER`. Both are optional: the runtime is uploaded asking for everything first, then without the browser, then without Python, and the first upload Cloudflare takes wins. The state records which the hots have (`python`, `browser`) and, for one that is missing, Cloudflare's own refusal (`tools_note`); the roster serves them so the tab and `veil hot` can say so. Removing the runtime removes the Python Worker after it.

- The local folder: each pass reads the roster, which carries every hot's event seq and notes revision and the scratchpad's seq, and asks for the rest only when one of them moved, so an idle account costs one call a minute. Events are read forward from the folder's own cursor (`.mirror.json`) and appended to `events.jsonl` and to `events.log` as `<UTC time>  r<iteration>  <kind>  <text>`, the text's own line breaks indented under it. Notes changed since the newest stamp held are written to `notes/`, and files of notes the hot deleted are removed; a note name outside the runtime's charset is never written. A deleted hot keeps its folder.
- Text limits: a goal or charter may hold `modelcfg.goalCharLimit(model)` characters, about a tenth of the model's context window (800 to 4000), the same function the desk's form counts against. The server refuses past it and sends the limit to the runtime as `text_max`, which clips a later `/goal` or `/charter` to it; changing a hot's model sends the new model's limit.
- An older runtime is replaced in place: when the state names this account and another build's script hash, the mirror pass uploads this build's (no class migration on a script that exists), and the hots keep their storage.

- The upload is five calls, in this order: read the account's workers.dev subdomain, ask whether the script exists, `PUT` the script (multipart: metadata + module), `PUT` the `HOT_TOKEN` secret, enable the workers.dev route. The metadata names the `AI` binding and the `Hot` object class and carries `keep_bindings: ["secret_text"]`, so the token is never part of a body that has to ride a file. The class migration (`new_sqlite_classes`) rides a first upload only; because the existence check is only a hint, an upload refused one way is tried the other way once and the first refusal is the one reported.
- A deployment that finds the state naming this account and this build's script hash costs no Cloudflare call. A different hash (a newer veil) uploads again before the next hot is created; hots already running keep their storage.
- The runtime's address must be `https://<name>.workers.dev`. A loopback address is accepted only while the Cloudflare API itself is a loopback stand-in (`NL_CF_API_ROOT`, the tests): there the stand-in plays the account's workers.dev too. A state file edited to name any other host gets no call, so the token cannot be sent elsewhere.
- A workers.dev address enabled a moment ago answers with Cloudflare's own page for a few seconds. Only right after an upload, the create call is retried (up to eight times, 2.5 s apart); a refusal in the runtime's own words is returned at once.
- A job's conversation is `hot_<name>_<job id>_<queued at>`. The stamp keeps a job from a hot that was deleted and deployed again under the same name out of the old hot's conversation. One job runs at a time per hot; a conversation that already has an answer is posted, not rerun, so a restart mid-job loses nothing; a conversation with messages and no answer is reported as a failed run.
- The bridge walks only admin accounts, as the routes do: a state file is just a file, and it must not start full-tool turns for an account that could not have deployed a hot.
- The Python Worker and the browser binding have not run on a live account. The browser's session protocol (`POST /v1/devtools/browser?keep_alive=`, then a WebSocket at `/v1/devtools/browser/<session>` carrying DevTools JSON) was taken from Cloudflare's own client source; the Python Worker follows Cloudflare's documented entry point. Against the stand-in, the Python Worker's code ran under the real interpreter.
- Verified against a stand-in API (`worker/fakehttp.zig`), end to end against a local stand-in that imports the uploaded script and serves it (deploy, the limit, the folder mirror, clearing the pad, deleting one hot and then the last), and by a first deployment on a live account (deploy, iterations, web fetches, notes, lessons, an inner swarm). Replacing an older runtime in place and removing the Worker with the last hot have run against the stand-in only.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
