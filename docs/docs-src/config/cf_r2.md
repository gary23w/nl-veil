# cf_r2

**File:** `src/config/cf_r2.zig`  
**Module:** `config`  
**Description:** The R2 chat/data backup for a "Log in with Cloudflare" user — an `nl-veil` bucket in the user's own account, filled by incremental background passes that use the OAuth token the chat already holds.

---

## Purpose Summary

A signed-in user's conversations and durable memories are copied into a bucket in their own Cloudflare account. It is a copy, not a move: nothing here deletes a local file. The module speaks the Cloudflare REST API rather than S3, because REST takes the Bearer token the vault already holds, where S3 would need separate R2 access keys. It needs the optional `workers-r2.write` scope and R2 activated on the account; when either is missing, the pass records Cloudflare's reason in the status and login is unaffected. There is no daemon: the OAuth callback kicks the first pass (which provisions the bucket), every status poll from a connected client re-arms a throttled auto pass, and "Sync now" is one POST. Each pass uploads only what changed since a persisted manifest and writes its outcome to a per-user state file the status route serves.

## Key Exports

- `BUCKET` — `"nl-veil"` for every user: the account boundary is the isolation, and object keys are still prefixed `u{uid}/` so two veil users sharing one Cloudflare account never collide
- `kickSync` — run a pass now on a detached thread; overlapping kicks collapse in the per-user singleflight
- `maybeAutoSync` — the heartbeat a connected status poll calls: a real pass at most every 900 s, and only while the user's `auto` switch is on
- `syncUser` — one incremental pass: token, bucket check/create, candidate walk, uploads, state write
- `r2Status` / `r2SyncNow` / `r2SetAuto` — the `GET /api/v1/oauth/cloudflare/r2`, `POST .../r2/sync` and `POST .../r2/auto` handlers; all `requireUser`-gated (tested), and "Sync now" answers 400 when the user is not connected

## Dependencies

- `httpz` + `../gateway/http.zig` — `App` (data dir, vault, `cf_oauth_accounts_url`), `requireUser`, `badReq`, `jstr`
- `cf_oauth.zig` — `resolveToken` (auto-refreshed bearer + account id), `CF_PROVIDER`, and `apiCall`, the one curl path to Cloudflare (bearer in a `-K` config file, body in a scratch file, 30 s `--max-time`)

## Usage Context

`main.zig` registers the three routes beside the OAuth ones and embeds this file in its route-gate audit (`ROUTE_MODS`). `cf_oauth.callback` calls `kickSync` after sealing a new login and writing its profile; `cf_oauth.status` calls `maybeAutoSync` on every poll from a connected user. The web Settings section (the `auto` checkbox and "Sync now") and the desk poller (`refreshCfR2`, read by the chat profile card and the Dashboard) render `r2Status`. `cf_oauth.logout` leaves the state file and manifest in place so a later login resumes incrementally.

## Notable Implementation Details

- What syncs: per conversation `messages.jsonl`, `context.json`, `digest.jsonl`, `brief.json`, `plan.jsonl` and `files.jsonl` under `_chat/convs/*/`, plus `.veil-desk/memories.jsonl`. Deliberately not: `events.jsonl` (huge, replayable), build workdirs, anything from the sealed vault, and `_sched/*.json` — the on-disk task files carry the real per-task provider keys, which `sched.zig` redacts only on its HTTP surface.
- Change detection: `.cf_r2_manifest.jsonl` keeps one `{p, sz, h}` line per uploaded file. `context.json` and `brief.json` are rewritten whole and can keep their length, so they are read and FNV-1a hashed every pass; every other file is compared by size alone, so a rewrite that lands on the same byte length between passes is missed until the size moves (`memories.jsonl` has such a path: forgetting a memory rewrites the file).
- Caps: one object is at most 8 MiB — a bigger file is counted in `skipped` and surfaced, so a frozen backup never reads as healthy. One pass uploads at most 32 files or 32 MiB, then sets `pending` and leaves the rest to the next pass.
- Bucket: GET it, else POST to create it; success or error code 10004 (the name already exists in this account) confirms it, and a failure stores Cloudflare's own message — most often R2 not activated. `bucket_ok` is sticky: once set, passes skip the check, nothing in the module clears it, and neither it nor the manifest records which Cloudflare account it refers to.
- Throttle: an in-memory 8-slot kick table (least recent evicted) keeps a frequent status poll free of file reads; the state file's `last_sync` is the durable second gate, so an eviction or a restart does not turn every poll into a pass. The singleflight table is also 8 slots, and a full table skips the pass rather than queueing it.
- Object keys are `u{uid}/{relpath}`, sent unencoded in the URL, so `keySafe` admits only letters, digits, `.`, `_`, `-` and `/`, at most 512 bytes, with no `..` and no leading or trailing slash; a path that fails is skipped silently (tested).
- The pass owns every state field except `auto`, which it re-reads just before writing, so a user who switched auto off mid-pass keeps that choice.
- Nothing is deleted remotely: a conversation removed locally keeps its objects in the bucket and its entries in the manifest totals (`files`, `bytes`).

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
