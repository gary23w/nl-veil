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

## Dependencies

- `httpz` + `../gateway/http.zig` — `App` (holds the env-overridable cf_oauth_* config) and `requireUser`
- `key_vault.zig` — `putOAuth`/`resolveOAuth`/`OAuthBundle`, the sealed at-rest store

## Usage Context

Routes are registered by the server; the desk drives start → browser consent → status polling. Config comes from `App` fields main.zig fills, so a deployment registers its OWN OAuth client and bakes only the public client_id in.

## Notable Implementation Details

- Pending-auth store: 16 fixed slots behind a mutex, 10-minute TTL, single-use take — an abandoned consent flow ages out. The uid rides the state so the unauthenticated browser callback can be attributed.
- Outbound HTTPS goes through curl with the form body in a scratch file (`--data-binary @file`) and any bearer in a curl config file (`-K`) — no secret ever lands on the argv; random suffixes keep concurrent flows apart.
- A refresh response may omit the refresh token; the old one is kept. A failed refresh surfaces as not-connected rather than an error, so callers fall back cleanly.
- The model list is cached in-process with a 15-minute TTL and dies on restart — every server start refetches; a fetch failure serves the stale cache when one exists.
- The callback always renders a small HTML page (success or short error) — it never 500s the user's browser tab.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
