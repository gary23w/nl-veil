# entitlements

**File:** `src/plan/entitlements.zig`  
**Module:** `plan`  
**Description:** Feature-entitlement gating: checks plan-level access rights before exposing premium functionality, with cached and on-demand evaluation.

---

## Purpose Summary

Feature-entitlement gating: checks plan-level access rights before exposing premium functionality, with cached and on-demand evaluation.

## Key Exports

- `Entitlements` struct — feature gate
- `check(feature)` — is feature allowed?
- `EntitlementCache` — TTL cache for fast lookups
- Plan-level feature manifests

## Dependencies

- `plan/neurons` — plan models and limits
- `auth/auth_core` — identity context
- Standard library: collections, time

## Usage Context

Checked before every premium feature access. Evaluated in the request path so latency is critical.

## Notable Implementation Details

Entitlements are cached with a TTL and invalidated on plan change events. The cache hierarchy is L1 (memory) / L2 (Redis).

---

*Documentation generated for nl-veil — entitlements.zig source analysis.*
