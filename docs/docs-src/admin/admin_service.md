# admin_service

**File:** `src/admin/admin_service.zig`  
**Module:** `admin`  
**Description:** Admin (god-mode) HTTP handlers — list users, moderate (ban/unban/delete), list/kill swarms, read the audit log.

---

## Purpose Summary

The `/api/v1/admin/*` route handlers. Every handler starts with `requireAdmin` and every mutation is written to the hash-chained audit log via `app.audit.record(admin.email, action, target)`. Also owns the instance-wide settings an operator holds: the shared provider key (stored in the sealed vault under reserved uid 0) and the live default-model config. These are plain functions on the same router and port as everything else — there is no separate admin service or admin port.

## Key Exports

- `adminUsers` — GET users with plan, live minds, swarm counts, banned flag
- `adminCreateUser` — POST mint an account (reuses `auth.register`: same validation, argon2id, duplicate-email refusal) for closed-registration onboarding
- `adminModerate` — POST ban/unban/delete by email; refuses to moderate the admin's own account
- `adminUserActivity` — GET one account's metadata: conv ids/sizes, swarms, grants — never message content
- `adminRecipes` / `adminSetRecipeGrant` — list the recipe registry; grant (must resolve in registry) or revoke (always allowed) a recipe for a user
- `adminPutKey` / `adminListKeys` / `adminDelKey` — the shared server key under uid 0; list is metadata only (provider, last4)
- `adminGetConfig` / `adminSetConfig` — read/set default+think+prompt model/base_url, live under a mutex, no restart; empty model clears the default
- `adminSwarms` / `adminKill` — list all swarms across users; force-remove one
- `adminAudit` — dump `audit.log` with an `X-Audit-Integrity` header from `audit.verify()`

## Dependencies

- `../gateway/http.zig` — `App`, `requireAdmin`, `badReq`/`notFound`/`serverErr`, `jstr`
- `../worker/chat/service.zig` — `SERVER_KEY_UID` (the reserved uid 0 namespace)
- `../config/server_config.zig` — the `Defaults` shape behind get/set config
- `httpz` — request/response types

## Usage Context

Routes are registered in `main.zig` under `/api/v1/admin/*`. The handlers act through the `App` singletons: `app.auth` (users), `app.sup` (swarms), `app.vault` (uid-0 key), `app.cfg` (defaults), `app.recipes`, `app.audit`.

## Notable Implementation Details

- Revoke-a-recipe deliberately skips the registry check (grant does not): a deleted recipe's grant must stay removable, or a later file under the same name goes live for stale holders.
- The shared uid-0 key is a billing decision: once set, every user without their own key spends the admin's credit; a user's own key always wins. The key value is never echoed or logged.
- `configJson` exists so the GET response uses the same field names as the POST body (`default_model`, not `model`) — the mismatch once made saved settings look discarded.
- `adminUserActivity` is metadata-only by design (conversation event streams carry shell output and file bodies), and reading it is itself audited as `read_activity`.
- `adminAudit` replies with content-type TEXT, not EVENTS — an empty EVENTS response uses SSE framing and leaves keep-alive clients hanging.

---

*Case file grounded in the module's `//!` header and public API.*
