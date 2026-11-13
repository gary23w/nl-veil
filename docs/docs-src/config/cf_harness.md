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

While the switch is on, a background thread (`bgLoop`) asks the harness for its unfinished local jobs (`GET /v1/local`, with this machine's node id once it has one) every 20 seconds. Each job runs as an unattended chat turn, through the same entry points a scheduled task and a tater-tot's job use, in a conversation named `harness_<job id>`, on the Cloudflare login and the job's model. One runs at a time. When a turn starts the server tells the harness (`POST /v1/local/<id> {started: true}`); when it has ended the server posts the turn's last answer (`{ok: true, result}`, cut to 10000 bytes), or a failure when the turn left no answer. The thread makes no call for a user who has neither set the switch nor reached a harness from this server, runs only for an admin account, and stops when `VEIL_CHAT_BACKEND=0`. A harness older than version 6 has no such route and nothing is started. A harness whose address is not known is looked for again every 5 minutes.

## Deploying the harness

A user with no harness does not have to go to the website for one. `POST /api/v1/harness/deploy` puts it into their own Cloudflare account with the login this server holds:

1. If a harness already answers, nothing is uploaded and the route says so (`deployed: false`).
2. The account's workers.dev subdomain is read. An account that has none yet is told to open Workers & Pages in the Cloudflare dashboard once.
3. The harness is uploaded as the Worker `veil-web`. The source is the copy compiled into this binary (`cloud/veil-web/veil-web.js` as it was at build time), not one fetched at deploy time. The upload carries what `cloud/veil-web/wrangler.jsonc` declares: the AI binding, the `Harness` object class, the page's origin, and, when the script is new, the migration that creates the class. The Worker Loader binding (Python) is not asked for; the harness adds it to itself when its owner asks.
4. Its workers.dev address is switched on.
5. The new address is asked for its status every 3 seconds for up to 24 seconds. The route answers `answering: false` when it had not answered by then; a new address can take longer to come up.

A refusal by Cloudflare comes back as a 502 with the reason; a login that lacks the permission to deploy Workers is told to log in again. A harness deployed this way keeps itself current from the public repo afterwards, as one deployed from the website does.

Nothing deploys on this server's own initiative. The route is called by the desk's and the web app's **Deploy my runtime** button, and by the chat verb `mesh_deploy_runtime`, whose description tells the model to call it only after the user has said yes. When a mesh verb reaches no runtime, its answer tells the model to ask the user whether to deploy one.

## The mesh

From version 10 the harness keeps a list of **nodes**: every veil logged in to the account that has told it "I am here". A machine joins when its harness first answers this server (`GET /api/v1/harness`): it is given an id, 16 random hex characters kept in the state file, and a name, the computer's own name until the owner sets one (`POST /api/v1/harness/node {name}`). From then on the harness thread says it is here on every pass (`POST /v1/nodes/<id>`, every 20 seconds): the name, `desk` or `server`, the operating system, the veil's version, whether the local-jobs switch is on (`runs`), whether this server has an Agent Garrett connection, and the names of the MCP servers found in this machine's MCP config files (names only, read again every 5 minutes). The harness lists a node as offline once it has not heard from it for 90 seconds. Nothing calls a machine: each one asks.

A job can be addressed to one node (`POST /api/v1/harness/jobs {task, model?, node}`). The harness hands it to that node only; this machine asks for `GET /v1/local?node=<its id>` and so receives the jobs addressed to it and the ones addressed to nobody, never another machine's. The switch is unchanged: a machine runs work only while its owner has it on, and it is what `runs` reports.

`GET /api/v1/harness/nodes` relays the harness's list (this machine says it is here first, so the list has it as it is now). `DELETE /api/v1/harness/nodes/:id` has the harness forget a node; one that is still running is listed again on its next pass.

### The chat's verbs

A chat turn whose user is logged in with Cloudflare and is not sandboxed is offered four more tools:

- `mesh_inventory` lists the nodes, one a line: id, name (this machine marked), kind, operating system, version, online or how long ago it was seen, whether it runs work, whether it has a browser, Agent Garrett, its MCP server names, and how many jobs wait for it.
- `mesh_run {node, task, model?}` sends a task to one node, named by its id or by its exact name when only one node has it. It refuses this machine itself, a node that does not run work, and a name no node (or more than one) has. It answers with the job id at once and says when the node is offline.
- `mesh_deploy_runtime` deploys the harness as described above; it does nothing when one already answers.
- `mesh_result {job}` reads that job: its state while it waits or runs, the other veil's report once it is done, its error when it failed.

They are refused for a sandboxed caller and for a user who is not the server's admin, like the routes.

## Shared settings

`GET` and `POST /api/v1/harness/settings` relay the harness's shared settings: small named values, each with the time the harness took it, where the last write of a name wins. The server checks only that a write is a JSON object of at most 64 KB; the harness checks the names and values. The desk is the user of these routes (see [meshsync](../desk/meshsync.md)).

## Agent Garrett, shared

The harness can hold an Agent Garrett connection (the web veil's Harness pane sets it). This server brings its own connection level with it, every 5 minutes and on `POST /api/v1/harness/share`:

- connected here and nothing on the harness: the key is given to the harness, which checks it with the agent before keeping it;
- nothing here and a key on the harness: it is taken, once for each connection the harness holds, so a disconnect made here afterwards is not undone;
- both hold a key and they differ: nothing is changed.

Only a key for the hosted agent travels; an agent of the owner's own, reached by address and token, stays where it was set up. The route answers what happened (`pushed`, `pulled`, `same`, `differs`, `none`) and never the key. The state file records the time of the harness connection last taken or given, never the key.

MCP servers are not copied between machines. A machine's MCP servers are named in the inventory, and a task sent to that machine with `mesh_run` can use them there.

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
- `listNodes` / `forgetNode` / `setNode` — `GET /api/v1/harness/nodes`, `DELETE /api/v1/harness/nodes/:id`, `POST /api/v1/harness/node {name}`
- `getSettings` / `putSettings` — `GET` and `POST /api/v1/harness/settings`
- `share` — `POST /api/v1/harness/share`
- `deploy` — `POST /api/v1/harness/deploy`: answers `{ok, deployed, answering, url, version}`
- `MESH_SCHEMA`, `isMeshTool`, `meshTool` — the chat's four mesh verbs and their entry from the chat engine
- `node_kind`, `node_version` — what this process tells the harness it is; `main.zig` sets them
- `bgLoop` — the thread that says this machine is here, brings the Agent Garrett connection level, and polls an allowed harness for local jobs and runs them (above)

## Answers

The harness's JSON is passed through as it is. A refusal by the harness (a full queue, a login it does not accept) comes back as a 400 with the harness's own words in `err`. When no harness is reached (no workers.dev subdomain, no answer, or an answer that is not the harness's) the route answers 502 with the reason. A caller not logged in with Cloudflare gets a 400 saying so.

## Tests

The Cloudflare API and the harness are one `fakehttp` stand-in. The tests cover the gate on every route, the address rule, the checks on a queued job, discovery and the remembered address, the relayed calls and the harness's refusals, an absent harness, a state file edited to name another host, the switch, a pushed conversation's body and id, a newer harness copy, and the bridge posting an ended turn's answer or its failure. The mesh tests cover the machine's id (made once, kept through a forgotten address), what it says about itself, an addressed job's body, the inventory text, `mesh_run`'s refusals and its one queued job, `mesh_result`, the node id on the local-jobs poll, and the Agent Garrett connection taken, not taken again after a disconnect, and given. The deploy tests cover the upload's metadata against `wrangler.jsonc`, the migration riding a new script only, nothing uploaded when a harness answers, the upload then the address then the wait, an account with no subdomain, and a refused upload. No test deploys to a real account. No test starts a chat turn. The harness's local-job routes are tested under node (`cloud/veil-web/veil-web.test.mjs`); that file is not one of the check script's gates.
