# admin_service

**File:** `src/admin/admin_service.zig`  
**Module:** `admin`  
**Description:** Provides the administrative REST API surface for system management, including health checks, configuration reload, and operational controls exposed to privileged clients.

---

## Purpose Summary

Provides the administrative REST API surface for system management, including health checks, configuration reload, and operational controls exposed to privileged clients.

## Key Exports

- `AdminService` struct — main service container
- `health_check()` — endpoint handler
- `reload_config()` — runtime config reload
- `AdminError` error set

## Dependencies

- `auth/auth_core` — session/token validation
- `config/key_vault` — vault access for admin keys
- `obs/audit_log` — audit event recording

## Usage Context

Called by privileged operators via HTTP. Runs on the admin interface port (separate from the public gateway).

## Notable Implementation Details

Uses a separate admin port to reduce attack surface. All mutations are audited. Configuration reload is hot — no restart required.

---

*Documentation generated for nl-veil — admin_service.zig source analysis.*
