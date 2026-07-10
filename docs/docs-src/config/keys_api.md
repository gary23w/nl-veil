# keys_api

**File:** `src/config/keys_api.zig`  
**Module:** `config`  
**Description:** HTTP API for managing vault entries — create, read, rotate, and delete secrets — authenticated by the auth subsystem.

---

## Purpose Summary

HTTP API for managing vault entries — create, read, rotate, and delete secrets — authenticated by the auth subsystem.

## Key Exports

- `KeysApi` struct — HTTP handlers
- `create_key_handler()`, `get_key_handler()`, `delete_key_handler()`
- `router()` — returns configured router group

## Dependencies

- `config/key_vault` — vault operations
- `auth/auth_core` — authentication
- `gateway/http` — request/response types

## Usage Context

Exposed to administrators. Requires elevated auth scopes for all endpoints.

## Notable Implementation Details

All responses redact secret values after the initial creation response. Delete is a soft-delete with a purge timer.

---

*Documentation generated for nl-veil — keys_api.zig source analysis.*
