# keys_api

**File:** `src/config/keys_api.zig`  
**Module:** `config`  
**Description:** BYOK key-vault HTTP handlers — POST a provider key (sealed, write-only), GET the metadata list, DELETE by provider.

---

## Purpose Summary

The user-facing HTTP shim over `KeyVault`: three handlers, each `requireUser`-gated and operating on the caller's own uid. A user can store a provider key, see metadata about what they have stored, and delete by provider — there is no route that returns a stored key, and no rotation verb beyond POSTing a replacement.

## Key Exports

- `putKey` — POST `{provider, key, base_url?}`; maps the vault's validation errors to specific 400 messages; replies 201 with provider, last4, and the SHA-256 fingerprint (computed from the submitted key — the key itself is never echoed)
- `listKeys` — GET the caller's `KeyMeta` list: provider, last4, fingerprint, base_url, created
- `delKey` — DELETE by `:provider`; idempotent (the vault's `del` returns nothing, the reply is always ok)

## Dependencies

- `../gateway/http.zig` — `App`, `requireUser`, `badReq`, `serverErr`
- `httpz` — request/response types
- (indirectly) `app.vault` — every handler is a call into `config/key_vault.zig`

## Usage Context

Registered in `main.zig` as `POST /api/v1/keys`, `GET /api/v1/keys`, `DELETE /api/v1/keys/:provider`. This is the per-user counterpart of `admin_service`'s `/api/v1/admin/keys`, which manages the shared uid-0 key through the same vault.

## Notable Implementation Details

- Validation lives in the vault; this layer only translates `BadProvider`/`BadKey`/`BadBaseUrl` into human-readable 400s (provider: `a-z0-9-_`, ≤32 chars; key: 1..512 chars, no quotes/backslashes/control chars).
- last4 + fingerprint in the 201 response are the caller's only future handle on the key — enough to check "is the key I hold the one stored" without the server ever revealing it.
- `listKeys` is built from vault metadata only; the sealed blobs are opened server-side but no key material crosses the wire.

---

*Case file grounded in the module's `//!` header and public API.*
