# auth_api

**File:** `src/auth/auth_api.zig`  
**Module:** `auth`  
**Description:** Auth HTTP handlers — register / login / logout / me, plus API-key create/list/revoke — thin shims over auth_core.

---

## Purpose Summary

The public auth surface: seven route handlers that parse the request, call `app.auth` (auth_core) or `app.keys` (api_keys), and shape the JSON reply. Sessions ride an `HttpOnly; SameSite=Strict` cookie set by `login`; `me` also accepts an `nlk_` API key as a fallback identity. There is no token-refresh flow and no CSRF machinery beyond the cookie attributes — the session token itself is the whole credential.

## Key Exports

- `register` — 403 while `open_registration` is off ("private beta"); otherwise delegates to `auth.register`
- `login` — gated per-IP by `app.login_guard` (429 when locked); on success sets the session cookie with `Max-Age=2592000` (30 days)
- `logout` — drops the session in auth_core and expires the cookie
- `me` — identity + entitlements + neuron metering + server default model; replies `authed:false` (with `open_registration` and defaults) rather than erroring when anonymous
- `keyCreate` — mints an API key; the raw key appears in this one response with a "shown only once" note
- `keyList` / `keyRevoke` — a user's key metadata; revoke by hash id

## Dependencies

- `../gateway/http.zig` — `App`, `COOKIE`, `sessionToken`, `requireUser`, `apiKeyFromReq`, error helpers
- `../plan/entitlements.zig` / `../plan/neurons.zig` — the plan limits and neuron balance `me` reports
- `httpz` — request/response types

## Usage Context

Registered in `main.zig` as `POST /api/v1/auth/register|login|logout`, `GET /api/v1/auth/me`, and `POST|GET /api/v1/apikeys` + `DELETE /api/v1/apikeys/:id`. The SPA calls `me` on load to decide what to render; login failures/successes feed `login_guard.fail`/`success`.

## Notable Implementation Details

- `login` consults the guard **before** touching credentials, and reports failure to it on bad credentials only — a locked IP never even reaches argon2 verification.
- `me` degrades instead of failing: unauthenticated callers still learn whether registration is open and what the default model is, which is what the login screen needs.
- `keyNameFromBody` is a deliberate hand-rolled scan for `"name"` in the raw body (capped at 60 chars, defaulting to "API key") rather than a full JSON parse.
- API keys are only readable as metadata after creation; the create response is the single moment the raw key exists on the wire.

---

*Case file grounded in the module's `//!` header and public API.*
