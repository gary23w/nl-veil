# api_keys

**File:** `src/auth/api_keys.zig`  
**Module:** `auth`  
**Description:** API keys — programmatic auth for the public API (alongside the SPA session cookie); only SHA-256 hashes are stored.

---

## Purpose Summary

Mints, verifies, lists and revokes `nlk_` bearer keys so scripts can call the API without a browser session. A key is 24 random bytes as hex behind the `nlk_` prefix; the server keeps only its SHA-256 hex hash plus display metadata (uid, sanitized name, created, `nlk_XXXXXXXX…` prefix), persisted base64-encoded in neuron-db under scope `k_<hash>` and mirrored in an in-memory map for fast verification. The raw key is returned exactly once, at creation.

## Key Exports

- `PREFIX` — `"nlk_"`, the literal every key starts with
- `View` — what listing exposes: id (the hash), display prefix, name, created
- `ApiKeys.init` / `warm` — construct; reload all `k_` scopes from neuron-db at boot
- `ApiKeys.create` — mint a key for a uid, store hash + metadata, return the raw key (only time it exists server-side)
- `ApiKeys.verify` — hash a presented key, look it up, return the owning uid or null
- `ApiKeys.list` — a uid's key views; never raw material
- `ApiKeys.revoke` — delete by hash id, only if the key belongs to the calling uid

## Dependencies

- `../worker/neuron/client.zig` — `Neuron`, the persistence backend (`put`/`get`/`del`/`scopes`)
- Std: `std.crypto.hash.sha2.Sha256`, `std.base64`, an `std.Io.Mutex` around the map

## Usage Context

Constructed and warmed in `main.zig`; hangs on the `App` as the optional `app.keys`. `auth_api.keyCreate/keyList/keyRevoke` are the HTTP surface (`/api/v1/apikeys`); `verify` is called by `requireUser` in `gateway/http.zig` (and by `auth_api.me`) when a request carries an `nlk_` bearer token instead of the session cookie.

## Notable Implementation Details

- Storage is hash-only: a leaked database yields no usable keys, and a lost key cannot be re-shown.
- There is no rotation, expiry, or scoping — a key maps to its uid until revoked. Banned-account refusal happens in the caller (`requireUser`), since `verify` only answers "whose key is this".
- Names are sanitized to 60 chars of `[A-Za-z0-9 ._-]` before being spliced into the stored JSON.
- `verify` requires the prefix and a minimum length before hashing, so junk input short-circuits.

---

*Case file grounded in the module's `//!` header and public API.*
