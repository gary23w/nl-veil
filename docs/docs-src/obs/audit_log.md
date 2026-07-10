# audit_log

**File:** `src/obs/audit_log.zig`  
**Module:** `obs`  
**Description:** Structured audit-logging subsystem that records security-relevant events (auth decisions, config changes, deployments) to a queryable event store.

---

## Purpose Summary

Structured audit-logging subsystem that records security-relevant events (auth decisions, config changes, deployments) to a queryable event store.

## Key Exports

- `AuditLog` struct — event recorder
- `Event` struct — typed event (actor, action, resource, result)
- `query()` — search events by filter
- `AuditLogConfig` — backend and retention settings

## Dependencies

- `config/key_vault` — optional encryption key for logs
- Standard library: time, serialization, I/O

## Usage Context

Called instrumentally by auth, config, deploy, and admin modules to record security-relevant events.

## Notable Implementation Details

Events are batched and written asynchronously to avoid blocking the hot path. The query engine supports time-range and actor/action filters.

---

*Documentation generated for nl-veil — audit_log.zig source analysis.*
