# auth_core

**File:** `src/auth/auth_core.zig`  
**Module:** `auth`  
**Description:** Auth — register / login / sessions, backed by neuron-db (dogfooded) with an in-memory user + session cache.

---

## Purpose Summary

The identity store. Users and sessions live in mutex-guarded in-memory maps and are persisted as base64-wrapped JSON in neuron-db (`u_<hash-of-email>` and `s_<token>` scopes); `warm()` rehydrates both at boot, dropping expired sessions as it goes. Passwords are argon2id hashes; session tokens are 24 random bytes as hex, minted at login and honored for 30 days server-side. There is no JWT, no signed token — a session is a random key into a map.

## Key Exports

- `Auth` — the store: `init`, `warm`, `register`, `login`, `logout`, `whoami`, `setPassword`, `seedDefaultAdmin`, `setAdminEmail`, `isAdmin`, `userById`, `idForEmail`, `userCount`, `listUsers`, `setPlan`, `setBanned`, `setToolGrant`, `hasToolGrant`, `deleteUser`
- `User` / `UserInfo` — the account record (id, email, pwhash, plan, created, banned, `tool_grants`)
- `AuthError` — `EmailTaken`, `BadCredentials`, `WeakInput`, `BadEmail`
- `Plan` — re-export from `plan/entitlements.zig`
- `DEFAULT_ADMIN_EMAIL` — `admin@neuron-loops.local`

## Dependencies

- `../worker/neuron/client.zig` — `Neuron`, the persistence backend
- `../plan/entitlements.zig` — the `Plan` enum
- Std: `std.crypto.pwhash.argon2` (argon2id, t=2 m=19456 p=1), `Sha256` for the user scope key

## Usage Context

Constructed, warmed, and admin-seeded in `main.zig`; `gateway/http.zig` re-exports `Auth`/`User` and every route resolves identity through `whoami`/`userById`. `auth_api` and `admin_service` are the HTTP surfaces; the recipe run gate checks `hasToolGrant` at turn start.

## Notable Implementation Details

- `isAdmin` compares email bytes **exactly**, on purpose: the earlier case-insensitive compare let a self-registered case variant of the admin address become a second, admin-classified account. Safe because `seedDefaultAdmin` registers the configured address verbatim.
- `login` verifies against a dummy argon2 hash when the account is unknown or banned, so timing does not reveal which emails exist.
- Session TTL is enforced server-side (30 days from `created`); the cookie's Max-Age is only a client hint. `warm()` rehydrating `s_` scopes is what keeps a restart from signing everyone out.
- `setPassword` rotates the hash on an existing account and drops that user's sessions; `setBanned(true)` and `deleteUser` drop them too.
- `tool_grants` is data, not capability — a grant only lets `runRecipe` dispatch that recipe under the user's own caps. `setToolGrant` rebuilds the list immutably and returns whether anything changed.
- Two tests pin the persist/reload record contract for grants and `setToolGrant`'s in-memory bookkeeping, both runnable without a live neuron.exe.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
