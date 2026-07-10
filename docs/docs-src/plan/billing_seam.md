# billing_seam

**File:** `src/plan/billing_seam.zig`  
**Module:** `plan`  
**Description:** Billing integration layer that meters resource usage, computes charges, and reports to external billing systems via a pluggable seam.

---

## Purpose Summary

Billing integration layer that meters resource usage, computes charges, and reports to external billing systems via a pluggable seam.

## Key Exports

- `BillingSeam` struct — billing adapter
- `report_usage()` — submit metering data
- `BillingRecord` — usage event type
- Supports pluggable backends (Stripe, custom)

## Dependencies

- `config/key_vault` — billing API keys
- Standard library: http client, json

## Usage Context

Integrated with the admin API and triggered on metering events. External billing API calls are asynchronous.

## Notable Implementation Details

Billing reports are queued and sent in batches. Supports dry-run mode for testing. Metering is eventually consistent.

---

*Documentation generated for nl-veil — billing_seam.zig source analysis.*
