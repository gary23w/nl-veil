# entitlements

**File:** `src/plan/entitlements.zig`  
**Module:** `plan`  
**Description:** Plans + entitlements — the server-side enforcement wall; `entitlements(plan, is_admin)` maps a user to their caps.

---

## Purpose Summary

Thirty lines defining the three plans and the pure function that turns a plan into hard caps. Every server-side limit check (swarm counts, mind counts, Cloudflare deploy, encryption) reads its numbers from this one switch, so the plan table cannot fork. There is no cache, no I/O, and no state — callers invoke the function and get a value struct back.

## Key Exports

- `Plan` — `enum { free, pro, max }`.
- `Entitlements` — the caps struct: `max_swarms`, `max_minds`, `per_swarm_minds`, `workers_ai`, `cloudflare_deploy`, `encrypted`.
- `entitlements(plan, is_admin) Entitlements` — pure mapping; the admin branch short-circuits before the plan switch.
- `monthlyNeuronGrant(plan) u64` — the metered-AI allowance per 30-day period: 500k (free) / 1.5M (pro) / 6M (max) neurons.

## Dependencies

- None — not even `std`. Pure data + switch.

## Usage Context

Imported wherever a limit is enforced or displayed: `auth/auth_core.zig`, `auth/auth_api.zig`, `admin/admin_service.zig`, `worker/deploy/service.zig`, `plan/neurons.zig` (grant lookup), and `plan/billing_seam.zig` (the upgrade pitch).

## Notable Implementation Details

- `is_admin=true` (the self-host / localhost operator) ignores the plan entirely and returns 10 swarms / 60 minds / 30 per swarm with everything enabled — the in-code comment explains the big per-swarm ceiling: a chat-cast can line up to 30 minds.
- `encrypted` is true only on the admin path; no paid plan grants it today.
- `workers_ai` is true on every plan; `cloudflare_deploy` is what free lacks.
- Being a pure function is the design: no TTLs, no invalidation, nothing to go stale.

---

*Case file grounded in the module's `//!` header and public API.*
