# cf_oauth

**File:** `src/config/cf_oauth.zig`  
**Module:** `config`  
**Description:** "Log in with Cloudflare" for Workers AI — an Authorization Code + PKCE flow (public client, no secret) that seals the token bundle in the key vault.

---

## Purpose Summary

The desk calls `POST .../start`; this module mints a CSRF `state` + PKCE verifier/challenge, remembers them, and returns the Cloudflare consent URL for the system browser. Cloudflare redirects the browser to `GET .../callback?code&state` on THIS server; the state is matched (single-use), the code is exchanged (+ verifier) for access + refresh tokens, the account id is resolved, and the bundle is sealed in the key vault under one uid. From then on the chat/cast paths call `resolveToken` and drive Workers AI with no pasted key — the token auto-refreshes and re-seals when near expiry. Disabled (start returns 501) until a client id is configured.

## Key Exports

- `DEFAULT_CLIENT_ID` — compiled-in public OAuth client id (empty = feature stays "not set up"); `NL_CF_OAUTH_CLIENT_ID` still overrides
- `CF_PROVIDER` — the vault slot `"cf-oauth"`, distinct from a manually pasted `workers-ai` BYOK key so the two never collide
- `resolveToken` — the entry chat + cast use: current access token + Workers AI base_url + account id for a uid, refreshing within 120 s of expiry; null = not connected (caller falls back)
- `start` / `callback` / `status` / `logout` — the `/api/v1/oauth/cloudflare/*` HTTP handlers (status never returns the token)
- `models` — `GET .../models`: the account's LIVE text-generation Workers AI model list for the desk dropdown (the catalog changes too fast to hardcode)
- `curl` + `CurlOpts` — the one Cloudflare transport in the process: this module's token legs, `apiCall`, and the `cf_` tool belt (`cftools.call`) all send their calls through it. Each caller brings its own scratch dir, body-file prefix, `--max-time`, answer cap and any extra argv
- `apiCall` — `curl` with the server's own options (the data dir, `.cfoauth-body-`, 30 s, 1 MiB); `cf_r2` and `cf_tunnel` make their v4 calls through it
- `ScratchWatch` + `test_before_curl` — TEST ONLY: a seam just before a call's curl starts, and a watcher that looks through a scratch dir for secrets there and from a stand-in mid-call; `cftools`' tests use both

## Dependencies

- `httpz` + `../gateway/http.zig` — `App` (holds the env-overridable cf_oauth_* config) and `requireUser`
- `key_vault.zig` — `putOAuth`/`resolveOAuth`/`OAuthBundle`, the sealed at-rest store
- `../worker/llm.zig` — `runCurl` and `KEY_CFG_MAX`: spawn curl, hand it its config over stdin, collect the answer

## Usage Context

Routes are registered by the server; the desk drives start → browser consent → status polling. Config comes from `App` fields main.zig fills, so a deployment registers its OWN OAuth client and bakes only the public client_id in.

## Notable Implementation Details

- Pending-auth store: 16 fixed slots behind a mutex, 10-minute TTL, single-use take — an abandoned consent flow ages out. The uid rides the state so the unauthenticated browser callback can be attributed.
- **The bearer never touches disk, and no secret lands on the argv.** `curl` builds curl's config in memory, runs curl with `-K -`, and writes the config into its stdin (`llm.runCurl`). The config holds the bearer (`header = "Authorization: Bearer ..."`), the content type, and the body as `data-raw = "..."` whenever it fits. It used to be a file: `{data}/.cfoauth-cfg-*` held the bearer and `{data}/.cfoauth-body-*` the token exchange's form (the refresh token, or the code and its verifier) for the whole call, inside a data dir that is often a synced folder. A sync client could upload them mid-call, deleting a synced file only sends the cloud copy to the recycle bin, and a process killed mid-call left them where they were.
- **What rides the config, and what a file.** A body rides the config when curl reads it back byte for byte and the whole config stays within `llm.KEY_CFG_MAX` (4096 bytes, what the stdin pipe holds with no reader, so the write never waits on curl). The token exchange's form always does. A body too big for that, or holding NUL or 0x1A, goes to `{scratch}/{body_prefix}{16 hex}` for its call's life and is deleted when the call returns: an upload's bytes, never the bearer. A bearer or content type holding a control byte, or a bearer too long for the pipe, fails the call before anything is written or dialed.
- **The escaping is what keeps a body a body.** Inside a quoted config value curl knows `\\`, `\"`, `\t`, `\n`, `\r` and `\v` (`llm.cfgEscape`, with `llm.cfgHeader` above it: both live in `worker/llm.zig` now, so the chat calls' configs and these ones are escaped by the same code), and every other byte reads back as itself. Unescaped, a line feed ends the value and curl reads the rest as options: measured on curl 8.5, 8.17 and 8.21, a body added a header and a second URL, and curl sent the config's bearer to that URL too. NUL and 0x1A have no escape (curl stops a line at NUL; on Windows it reads the config in text mode, where 0x1A ends it). The option is `data-raw`, not `data-binary`, because `data-binary` reads a value starting with `@` as a file name: all three curls uploaded that file instead of the body.
- The transport tests drive the real curl against a 127.0.0.1 stand-in. `ScratchWatch` looks through every file under the call's scratch dir at `test_before_curl` and again from the stand-in while curl waits on the reply (`fakehttp.Server.startWatched`), then once more after the call returns. The tests check that a body arrives byte for byte (every byte curl's config can carry, a leading `@`, a body that tries to add a header and a URL), that a body past the pipe rides a file that never holds the bearer and is gone afterwards, that a header value the config cannot carry is refused before curl starts, and that a refresh, a code exchange and a bearer call leave none of their secrets, nor the tokens that come back, on disk.
- A refresh response may omit the refresh token; the old one is kept. A failed refresh surfaces as not-connected rather than an error, so callers fall back cleanly.
- The model list is cached in-process with a 15-minute TTL and dies on restart — every server start refetches; a fetch failure serves the stale cache when one exists.
- The callback always renders a small HTML page (success or short error) — it never 500s the user's browser tab.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
