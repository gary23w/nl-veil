# cf_harness

**File:** `src/config/cf_harness.zig`  
**Module:** `config`  
**Description:** The web veil's worker harness, reached from this server. It finds the `veil-web` Worker in the user's own Cloudflare account and relays a small set of calls to it with the Cloudflare login the server already holds.

---

## Purpose Summary

The browser chat works through one Worker in the user's own Cloudflare account, `veil-web` (`cloud/veil-web/veil-web.js`). That Worker keeps a job queue, schedules, chats, usage and limits. This module lets the server see the same queue.

The harness accepts any Cloudflare OAuth access token that belongs to the account owning its workers.dev name. The server already holds that login (`cf_oauth.resolveToken`), so there is no new credential. The module asks the Cloudflare API for the account's workers.dev subdomain (`cf_tot.workersSubdomain`), builds `https://veil-web.<subdomain>.workers.dev`, and sends each call there with the login as its bearer. Calls go from this machine straight to the user's Worker.

The login is sent only to `https://veil-web.<name>.workers.dev`. While the Cloudflare API root is a loopback stand-in (`NL_CF_API_ROOT`, the tests), the stand-in's own loopback address is accepted instead. The address is written to `{data}/u{uid}/cf_harness.json` once the harness has answered there, beside the account id it belongs to and the local-jobs switch; the file holds no secret. A remembered address that stops answering as a harness is forgotten (the switch stays), and a file naming any other host gets no call: the account is asked again.

Every route is admin-gated, like the tots: a queued job spends the account's Workers AI, and a local job runs a full-tool turn on this machine.

## Local jobs

From version 6 the harness accepts a job queued with `local: true`. It does not run that job in the cloud; the job waits for the owner's machine. Nothing listens on the machine for it. This server asks.

The owner turns it on with `POST /api/v1/harness/local {on: true}` (the desk's checkbox, the web app's button). The choice is kept in this server's state file, off until set. The harness is not told and cannot set it. Whoever holds the account's Cloudflare login can queue a local job, and its turn has this machine's tools: that is what the switch grants.

While the switch is on, a background thread (`bgLoop`) asks the harness for its unfinished local jobs (`GET /v1/local`) every 20 seconds. Each job runs as an unattended chat turn, through the same entry points a scheduled task and a tater-tot's job use, in a conversation named `harness_<job id>`, on the Cloudflare login and the job's model. One runs at a time. When a turn starts the server tells the harness (`POST /v1/local/<id> {started: true}`); when it has ended the server posts the turn's last answer (`{ok: true, result}`, cut to 10000 bytes), or a failure when the turn left no answer. The thread makes no call for a user who has not set the switch, runs only for an admin account, and stops when `VEIL_CHAT_BACKEND=0`. A harness older than version 6 has no such route and nothing is started. A harness whose address is not known is looked for again every 5 minutes.

## Chats

The harness keeps the web chat's conversations. Reading them is a relay: `GET /api/v1/harness/convs` lists them as the harness does, newest first, and `GET /api/v1/harness/convs/:id` returns one whole.

`POST /api/v1/harness/convs {conv}` pushes one of this server's conversations (`{data}/u{uid}/_chat/convs/<id>`) up to the harness in the web chat's shape. What goes: the conversation's user and assistant messages as text, in order; a title (the first message, one line, cut to 80 bytes); and the time of its last message. What does not go: the engine's own rows, tool rows, and the conversation's work folder (the harness chat's `files` is sent empty). The harness id is `d` followed by 20 hex characters of a hash of the conversation's id, so pushing the same conversation again replaces the same harness chat. The harness keeps its own copy when that one is newer; the route then answers `stale: true` and nothing was replaced. A conversation with no messages, or one whose push would pass 1.5 MB, is refused before any call. Nothing is pushed unless asked, and nothing is written into this server's conversations from the harness. A conversation that exists only inside the desk (the desk's local chat engine) is not on this server and cannot be pushed.

## Key Exports

- `SCRIPT`, `TASK_MAX` — `"veil-web"`, `8000`
- `status` — `GET /api/v1/harness`: `connected` (logged in with Cloudflare), `reachable`, `url`, `err`, `default_model`, and `harness`, which is the harness's own `GET /v1/status` answer as it sent it, or `null`. Always 200 for a gated caller, so a client can show each state
- `listJobs` — `GET /api/v1/harness/jobs`: the harness's queue as it reports it, oldest first
- `queueJob` — `POST /api/v1/harness/jobs {task, model?}`: queues a job. The task must be 1 to 8000 characters and the model a Workers AI id (it starts with `@`); with no model the server's default Cloudflare model is sent. Both are checked before any call
- `getJob` / `cancelJob` — `GET` and `DELETE /api/v1/harness/jobs/:id`: one job whole, and cancel or delete one. The id must be lower-case letters and digits, 1 to 32
- `listSchedules` — `GET /api/v1/harness/schedules`: the harness's schedules
- `setLocal` — `POST /api/v1/harness/local {on}`: the owner's switch for local jobs on this machine; `status` reports it as `local`
- `listConvs` / `getConv` — `GET /api/v1/harness/convs` and `/convs/:id`: the harness's chats, and one whole (the id must be 6 to 24 lower-case letters and digits)
- `pushConv` — `POST /api/v1/harness/convs {conv}`: copy one of this server's conversations up; answers `{ok, id, msgs, stale}`
- `bgLoop` — the thread that polls an allowed harness for local jobs and runs them (above)

## Answers

The harness's JSON is passed through as it is. A refusal by the harness (a full queue, a login it does not accept) comes back as a 400 with the harness's own words in `err`. When no harness is reached (no workers.dev subdomain, no answer, or an answer that is not the harness's) the route answers 502 with the reason. A caller not logged in with Cloudflare gets a 400 saying so.

## Tests

The Cloudflare API and the harness are one `fakehttp` stand-in. The tests cover the gate on every route, the address rule, the checks on a queued job, discovery and the remembered address, the relayed calls and the harness's refusals, an absent harness, a state file edited to name another host, the switch, a pushed conversation's body and id, a newer harness copy, and the bridge posting an ended turn's answer or its failure. No test starts a chat turn. The harness's local-job routes are tested under node (`cloud/veil-web/veil-web.test.mjs`); that file is not one of the check script's gates.
