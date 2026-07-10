# auth_core

**File:** `src/auth/auth_core.zig`  
**Module:** `auth`  
**Description:** Implements core authentication primitives: token creation and verification, session management, password hashing, and identity resolution.

---

## Purpose Summary

Implements core authentication primitives: token creation and verification, session management, password hashing, and identity resolution.

## Key Exports

- `Token` struct — JWT-like signed token
- `Session` struct — session state
- `verify_token()` — validates signature and expiry
- `create_session()` — establishes new session

## Dependencies

- `config/key_vault` — signing key retrieval
- Standard library: crypto, time, base64

## Usage Context

Called by auth_api, login_guard, and any subsystem needing identity or token operations. Central to the security model.

## Notable Implementation Details

Uses constant-time comparison for token signatures. Sessions are stored in a configurable backend (memory, Redis, Postgres).

---

*Documentation generated for nl-veil — auth_core.zig source analysis.*
