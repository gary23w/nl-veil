# cftools

**File:** `src/worker/cftools.zig`  
**Module:** `worker`  
**Description:** The `cf_` tool belt — six tools that build on the user's own connected Cloudflare account: deploy a Worker, move objects through R2, query D1, and call any other v4 endpoint.

---

## Purpose Summary

A Cloudflare login connects the user's own account; this family lets the assistant build on it instead of only running inference against it. Five verbs cover what a build does — ship a Worker to a live `workers.dev` URL, list, put and get R2 objects, run SQL on D1 — and `cf_api` reaches the rest of the REST surface (Pages, KV, Queues, Vectorize, routes, Workers AI) without forty near-identical wrappers. The module resolves no credentials of its own: the chat turn resolves one token per turn and passes it down, and a blank token or account makes every `cf_` verb refuse before a request is built. A failed call hands the model Cloudflare's own error text, which is also how a scope the user declined on the consent screen shows up.

## Key Exports

- `Ctx` — the slice of `ToolCtx` the belt needs (allocator, io, scratch dir, workdir jail, token, account, `api_root`), passed explicitly so this file never imports `tools.zig`
- `API` — `https://api.cloudflare.com/client/v4`, the default root and the host the bearer is minted for
- `isLoopbackRoot` — the check `main.zig` applies to `NL_CF_API_ROOT`: only an `http://127.0.0.1:` or `http://localhost:` root may replace `API`
- `safeRel` — the jail for every file argument: a relative path inside the workdir (tested)
- `dispatch` — route a `cf_` call; null for any other name, so the caller's own chain continues (tested)
- `SCHEMA` — the six function definitions: `cf_deploy_worker`, `cf_r2_list`, `cf_r2_put`, `cf_r2_get`, `cf_d1_query`, `cf_api`; a test pins that it parses and names exactly the verbs `dispatch` routes

## Dependencies

- `std` only; Cloudflare is reached by spawning `curl`, which must be on PATH

## Usage Context

`engine.runTurn` calls `cf_oauth.resolveToken` once per turn and sets `ToolCtx.cf_token`, `cf_account` and `cf_api_root`; `buildTurnTools` appends `SCHEMA` only when token and account are both non-empty. No other `ToolCtx` construction sets them, so swarm minds, the CLI and `veil exec-tool` can neither see nor run the family. `tools.zig`'s dispatcher (`executeInner`) hands every `cf_`-prefixed name to `dispatch` with the run dir as scratch, after the sandbox gate — whose allowlist names no `cf_` verb, so a non-admin (`.sandboxed`) turn is refused there — and `isBuiltinTool` reserves the whole `cf_` prefix against recipes and authored tools. A call therefore runs with credentials only in a server-side admin turn (the web client's turns, scheduled tasks); a client-mode turn (`tool_client:true`, which the desk and the CLI chat send) delegates each call to `veil exec-tool`, whose context carries no Cloudflare credentials, so `dispatch` answers "not connected". `main.zig` uses `isLoopbackRoot` to accept or reject `NL_CF_API_ROOT`, which `scripts/sim/cfworld.py` points at a loopback stand-in. The web client renders `cf_` calls as Cloudflare steps and links the URL a deploy returns; the desk gives each verb a chip label.

## Notable Implementation Details

- Transport matches `cf_oauth`: the bearer rides a curl config file (`-K`) and a request body a scratch file (`--data-binary @file`), both in the run dir under a random 16-hex suffix and deleted when the call returns, so no secret or payload reaches the argv. Each call has a 120 s `--max-time`.
- Size caps: 8 MiB for a response, 24 MiB for an uploaded script or object. A response over the cap fails the call, and the failure reads as "could not reach the Cloudflare API" — so `cf_r2_put` can store an object that `cf_r2_get` cannot fetch back (anything over 8 MiB).
- `safeRel` refuses an empty path, one over 400 bytes, a leading `/` or `\`, any `..`, a drive letter and control characters, before the path is joined. Bucket names, object keys and `database_id` pass the same check; `cf_r2_list`'s `prefix` is not checked, nothing is URL-encoded, and a bucket listing asks for `per_page=100` without paging further.
- `cf_api` keeps the bearer on the API host rather than restricting what it does there: the path must start with a single `/` and contain no `://`, `@`, spaces or control characters, and it is appended to the root (tested against `https://`, `//`, `@` and space tricks). `{account_id}` is filled in; the method must be GET, POST, PUT, PATCH or DELETE. There is no path allowlist — a call reaches whatever the login's grant covers, which, since the tunnel scopes joined the default scope set, can include DNS, tunnel and zone-level Access writes the user granted.
- `isLoopbackRoot` also requires 18–200 bytes and rejects whitespace, `@`, `\`, `#`, `?` and a second `://`, so an override can only point the token at a process on the same machine.
- `cf_deploy_worker`: the name is at most 63 characters of `a-z`, `0-9`, `-` and `_`; the upload is one multipart PUT whose metadata sets `main_module` to `worker.mjs` (compatibility date defaulting to `2026-01-01`) and whose only module is the workspace file — its path rides the argv through `-F`, the token does not. Enabling the `workers.dev` route and reading the account subdomain are best-effort; without the subdomain, the reply says the script is deployed and points at the dashboard.
- A successful answer comes back as raw JSON for the model to read; a v4 envelope with `success:false` and an error becomes "`… FAILED — Cloudflare says: <message>`". `cf_r2_get` writes any body that is not such an envelope into the workspace as the object's bytes, at `file` or else at the key.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
