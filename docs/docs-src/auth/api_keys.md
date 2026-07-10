# api_keys

**File:** `src/auth/api_keys.zig`  
**Module:** `auth`  
**Description:** Implements API key generation, storage, rotation, and revocation used by the authentication subsystem to secure machine-to-machine communication.

---

## Purpose Summary

Implements API key generation, storage, rotation, and revocation used by the authentication subsystem to secure machine-to-machine communication.

## Key Exports

- `ApiKey` struct — key metadata (id, hash, scopes, expiry)
- `generate_key()` — creates new key pair
- `rotate_key()` — replaces key while keeping old valid briefly
- `revoke_key()` — invalidates a key immediately

## Dependencies

- `auth/auth_core` — base auth types
- `config/key_vault` — secure key storage
- Standard library: crypto, time

## Usage Context

Used by the auth subsystem during key creation flows and by the gateway to validate incoming API key headers.

## Notable Implementation Details

Keys are hashed with Argon2 before storage; only the truncated prefix is logged for identification. Rotation keeps the previous key valid for a configurable overlap window.

---

*Documentation generated for nl-veil — api_keys.zig source analysis.*
