# neurons

**File:** `src/plan/neurons.zig`  
**Module:** `plan`  
**Description:** The neuron ledger — the metered-AI budget that makes multi-tenant Workers AI safe to deploy: a per-user grant plus usage tally.

---

## Purpose Summary

An AI-spend ledger, not a compute-quota system: "neurons" are the billing unit for hosted inference tokens. Each user has one record `{used, topup, period_start}` persisted in neuron-db under scope `n_<uid>` as base64-encoded JSON; the granted amount is `monthlyNeuronGrant(plan) + topup`, and `used` resets when the 30-day period rolls over (top-ups survive the rollover). `neuronsForModel` converts a model's token counts into neurons via per-model rates.

## Key Exports

- `NeuronLedger` — the ledger over a `Neuron` (neuron-db) client: `init(gpa, nb)`, `status(uid, plan) Status`, `hasBalance(uid, plan) bool`, `charge(uid, neurons)`, `addTopup(uid, neurons)`.
- `Status` — `{ granted, used, balance (i64, can go negative), period_start }`.
- `neuronsForModel(model, tokens_in, tokens_out) u64` — rate table keyed by substring match on the model name (70b / 8b / coder-or-qwen buckets, plus a default), expressed as neurons per million tokens in/out.

## Dependencies

- `../worker/neuron/client.zig` — the `Neuron` get/put/del client the records ride on.
- `entitlements.zig` — `Plan` and `monthlyNeuronGrant`.
- `std` — JSON, base64, `std.Io.Mutex`, timestamps.

## Usage Context

One ledger is created in `src/main.zig` at server start and hung off the gateway `App` (`http.zig` `App.ledger`). `worker/deploy/service.zig` gates deploys with `hasBalance` and applies admin top-ups; `worker/control/supervisor.zig` calls `charge` with per-user usage collected from workers. The worker itself only *reports* cumulative neurons (run.zig keeps an inline mirror of the rate table); the control plane is what charges.

## Notable Implementation Details

- Every public op takes the ledger's `std.Io.Mutex` (`lockUncancelable`) around a load → mutate → save cycle, so concurrent charges cannot lose updates.
- `fresh()` lazily stamps `period_start` on first touch and zeroes `used` (not `topup`) once `now - period_start >= 30 days`.
- Arithmetic is saturating (`+|`, `*|`) — a garbage token count cannot overflow the record.
- All persistence failures degrade to a zeroed record / no-op; the ledger is deliberately best-effort rather than a hard dependency of the request path.

---

*Case file grounded in the module's `//!` header and public API.*
