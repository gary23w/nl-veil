# billing_seam

**File:** `src/plan/billing_seam.zig`  
**Module:** `plan`  
**Description:** The billing seam — `POST /billing/checkout` returns the Pro upgrade pitch; billing itself goes live with the Cloudflare deploy.

---

## Purpose Summary

A 20-line stub that reserves the checkout endpoint's shape before any payment machinery exists. The handler authenticates the caller, then answers with `status: "coming_soon"` plus a structured upgrade pitch: Pro at $15/month, with the swarm/mind caps pulled live from the entitlements table and the Workers AI + Cloudflare-deploy flags. Nothing is charged, stored, or provisioned.

## Key Exports

- `billingCheckout(app, req, res)` — the sole export: an httpz handler that requires a signed-in user, then responds with `{ ok, status: "coming_soon", plan, upgrade{...}, note }`.

## Dependencies

- `httpz` — request/response types.
- `../gateway/http.zig` — `App` and `requireUser` (the auth gate).
- `../plan/entitlements.zig` — `entitlements(.pro, false)` supplies the pitched caps.

## Usage Context

Registered in `src/main.zig` as `router.post("/api/v1/billing/checkout", billing_seam.billingCheckout, .{})`. A client calling checkout today gets the pitch, not a payment flow.

## Notable Implementation Details

- The pitch's `max_swarms` / `max_minds` numbers are read from the real entitlements function at request time, so the sales copy can never drift from what the enforcement wall would actually grant.
- The response `note` states the plan: Pro autoscales onto Cloudflare with hosted Workers AI inference (no BYOK), and billing goes live with that deploy.
- No payment provider, ledger write, or persistence of any kind lives here — this file is the seam where those will attach.

---

*Case file grounded in the module's `//!` header and public API.*
