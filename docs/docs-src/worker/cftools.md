# cftools

**File:** `src/worker/cftools.zig`  
**Module:** `worker`  
**Description:** The `cf_` tool belt — six tools that build on the user's own connected Cloudflare account: deploy a Worker, move objects through R2, query D1, and call any other v4 endpoint.

---

## Purpose Summary

A Cloudflare login connects the user's own account; this family lets the assistant build on it instead of only running inference against it. Five verbs cover what a build does — ship a Worker to a live `workers.dev` URL, list, put and get R2 objects, run SQL on D1 — and `cf_api` reaches the rest of the REST surface (Pages, KV, Queues, Vectorize, routes, Workers AI) without forty near-identical wrappers. The module resolves no credentials of its own: the chat turn resolves one token per turn and passes it down, and a blank token or account makes every `cf_` verb refuse before a request is built. A failed call hands the model Cloudflare's own error text, which is also how a scope the user declined on the consent screen shows up.

## Key Exports

- `Ctx` — the slice of `ToolCtx` the belt needs (allocator, io, scratch dir, workdir jail, token, account, `api_root`), passed explicitly so this file never imports `tools.zig`; `wrote` is an optional receipt `cf_r2_get` sets once a download has landed in the workdir
- `API` — `https://api.cloudflare.com/client/v4`, the default root and the host the bearer is minted for
- `isLoopbackRoot` — the check `main.zig` applies to `NL_CF_API_ROOT`: only an `http://127.0.0.1:` or `http://localhost:` root may replace `API`
- `MAX_REL` / `safeRel` — the jail for every file argument: a relative path inside the workdir, at most 400 bytes (tested)
- `FileUse` / `fileUse` — the one workspace file a call touches and which way: `reads` for `cf_deploy_worker`'s module and `cf_r2_put`'s `file`, `writes` for `cf_r2_get`'s destination, `none` otherwise, including arguments the verb refuses before opening anything. It reads the path through the same helpers the verbs use (`deploySource`, `putSource`, `getDest`); tests run the real verbs against a loopback stand-in and check that the file named is the one uploaded or written
- `dispatch` — route a `cf_` call; null for any other name, so the caller's own chain continues (tested)
- `SCHEMA` — the six function definitions: `cf_deploy_worker`, `cf_r2_list`, `cf_r2_put`, `cf_r2_get`, `cf_d1_query`, `cf_api`; a test pins that it parses and names exactly the verbs `dispatch` routes

## Dependencies

- `../config/cf_oauth.zig` — `curl`, the one Cloudflare transport in the process; this file passes it the run dir, `.cfapi-body-`, 120 s, 8 MiB and any multipart parts. Cloudflare is reached by spawning `curl`, which must be on PATH. Its tests also use `cf_oauth.ScratchWatch`

## Usage Context

`engine.runTurn` calls `cf_oauth.resolveToken` once per turn and sets `ToolCtx.cf_token`, `cf_account` and `cf_api_root`. No other `ToolCtx` construction sets them, so swarm minds and `veil exec-tool` can neither see nor run the family. `buildTurnTools` appends the belt only when token and account are both non-empty; for a `.sandboxed` (non-admin) turn it appends `tools.sandboxSchema(SCHEMA)`, which is derived from the same allowlist the sandbox gate in `tools.zig`'s `executeInner` checks. That allowlist names no `cf_` verb, so a non-admin turn is neither shown the family nor able to run it (tested). `executeInner` hands every `cf_`-prefixed name to `dispatch` with the run dir as scratch, and `isBuiltinTool` reserves the whole prefix against recipes and authored tools.

Every call runs in the server process. A server-side turn (the web client, scheduled tasks) reaches `dispatch` through `tools.execute`. A client-mode turn (`tool_client:true`, which the desk and `veil chat` send, honoured for an admin only) routes the family to `engine.cfClientTool` instead of delegating it, because the client executor holds no Cloudflare credentials. There `fileUse` names the one file the call touches, and it crosses the machine boundary over the [sync](#doc=worker/chat/sync) channel:

- **Upload** (`reads`): before the call the engine pulls the client's copy into the server's copy of the conversation workdir. If the client does not answer, or answers without the file, the call is refused and nothing is sent to Cloudflare. The server's copy, possibly older, is never uploaded instead.
- **Download** (`writes`): after the call sets `Ctx.wrote`, the engine pushes the file to the client (`file_sync`) and reads it back (`file_pull`). A download that does not arrive byte-identical is reported as not on the user's machine.

The same-disk probe skips both transfers when the desk shares the server's data folder, so binary and large files work there exactly as in a server-side turn. Only a client on another disk is held to the channel's limits: text, at most `cync.FILE_CAP` (512 KiB).

`main.zig` uses `isLoopbackRoot` to accept or reject `NL_CF_API_ROOT`, which `scripts/sim/cfworld.py` points at a loopback stand-in. The web client renders `cf_` calls as Cloudflare steps and links the URL a deploy returns; the desk gives each verb a chip label.

## Notable Implementation Details

- Transport is `cf_oauth.curl`, shared with the login, R2 and tunnel calls. The bearer rides the config curl reads from its stdin (`-K -`), so no file holds it, not even while curl runs, and nothing secret reaches the argv. A body rides the same config (`data-raw`, escaped) when the whole config fits the 4096-byte pipe: a `cf_api` body carrying a Worker secret, a D1 query. A body too big for that, or holding NUL or 0x1A, is written to `{run dir}/.cfapi-body-{16 hex}` while its call runs and then deleted: a `cf_r2_put` upload, a large `cf_api` payload. Before, the config was a file too (`.cfapi-cfg-*`, bearer included), and so was every body (`.cfapi-body-*`), each for up to the whole 120 s `--max-time`. A test drives three verbs against a 127.0.0.1 stand-in and looks through the run dir at the moment curl starts, while curl waits on the reply, and after the call: no file holds the token or the Worker secret, the small bodies wrote no file, and the upload's one body file is gone once the call returns.
- Size caps: 8 MiB for a response, 24 MiB for an uploaded script or object. A response over the cap fails the call, and the failure reads as "could not reach the Cloudflare API" — so `cf_r2_put` can store an object that `cf_r2_get` cannot fetch back (anything over 8 MiB).
- `safeRel` refuses an empty path, one over 400 bytes, a leading `/` or `\`, any `..`, a drive letter and control characters, before the path is joined. Bucket names, object keys and `database_id` pass the same check; `cf_r2_list`'s `prefix` is not checked, nothing is URL-encoded, and a bucket listing asks for `per_page=100` without paging further.
- `cf_api` keeps the bearer on the API host rather than restricting what it does there: the path must start with a single `/` and contain no `://`, `@`, spaces or control characters, and it is appended to the root (tested against `https://`, `//`, `@` and space tricks). `{account_id}` is filled in; the method must be GET, POST, PUT, PATCH or DELETE. There is no path allowlist — a call reaches whatever the login's grant covers, which, since the tunnel scopes joined the default scope set, can include DNS, tunnel and zone-level Access writes the user granted.
- `isLoopbackRoot` also requires 18–200 bytes and rejects whitespace, `@`, `\`, `#`, `?` and a second `://`, so an override can only point the token at a process on the same machine.
- `cf_deploy_worker`: the name is at most 63 characters of `a-z`, `0-9`, `-` and `_`; the upload is one multipart PUT whose metadata sets `main_module` to `worker.mjs` (compatibility date defaulting to `2026-01-01`) and whose only module is the workspace file — its path rides the argv through `-F`, the token does not. Enabling the `workers.dev` route and reading the account subdomain are best-effort; without the subdomain, the reply says the script is deployed and points at the dashboard.
- A successful answer comes back as raw JSON for the model to read; a v4 envelope with `success:false` and an error becomes "`… FAILED — Cloudflare says: <message>`". `cf_r2_get` writes any body that is not such an envelope into the workspace as the object's bytes, at `file` or else at the key, creating the destination's folders first (a key is path-shaped, and its folders need not exist), and only then sets `Ctx.wrote`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
