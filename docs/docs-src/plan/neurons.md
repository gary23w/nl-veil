# neurons

**File:** `src/plan/neurons.zig`  
**Module:** `plan`  
**Description:** The neuron ledger — the metered-AI budget that makes multi-tenant Workers AI safe to deploy: a per-user grant plus usage tally.

---

## Purpose Summary

An AI-spend ledger, not a compute-quota system: "neurons" are the billing unit for hosted inference tokens. Each user has one base64-encoded JSON record under `n_<uid>` containing usage, top-up credit, top-up retry IDs, and any pending run debit. Each metered run has a separate cumulative checkpoint under `nr_<uid>_<run-id>`. The displayed grant is `monthlyNeuronGrant(plan) + topup`; `used` resets after 30 days, while top-up credit and run checkpoints carry over. `neuronsForModel` converts token counts into neurons via per-model rates.

## Key Exports

- `NeuronLedger` — the ledger over a `Neuron` (neuron-db) client: `init(gpa, nb)`, fallible `status(uid, plan)` and `hasBalance(uid, plan)`, `prepareRun(uid, run_id, baseline)`, `chargeRun(uid, run_id, cumulative)`, `charge(uid, neurons)` for direct internal use, and `addTopup(uid, neurons, operation_id)`. A top-up ID has the form `t<unix-seconds>_<unique nonce>` (for example, `t1791853200_a1b2c3d4e5f6`). Reuse the same ID only to retry the same amount for the same account, within 90 days.
- `Status` — `{ granted, used, balance (i64, can go negative), period_start }`.
- `neuronsForModel(model, tokens_in, tokens_out) u64` — rate table keyed by substring match on the model name (70b / 8b / coder-or-qwen buckets, plus a default), expressed as neurons per million tokens in/out.

## Dependencies

- `../worker/neuron/client.zig` — the `Neuron` get/put/del client the records ride on.
- `entitlements.zig` — `Plan` and `monthlyNeuronGrant`.
- `std` — JSON, base64, `std.Io.Mutex`, timestamps.

## Usage Context

One ledger is created in `src/main.zig` at server start and hung off the gateway `App` (`http.zig` `App.ledger`). `worker/deploy/service.zig` settles current usage, checks balance, registers a new run, and applies admin top-ups; `worker/control/supervisor.zig` calls `chargeRun` with cumulative usage collected from workers. The worker itself only *reports* cumulative neurons (run.zig keeps an inline mirror of the rate table); the control plane is what charges.

## Notable Implementation Details

- Every public op takes the ledger's `std.Io.Mutex` (`lockUncancelable`) around a load → mutate → save cycle, so concurrent charges cannot lose updates.
- `fresh()` lazily stamps `period_start` on first touch and zeroes `used` (not `topup`) once `now - period_start >= 30 days`.
- Arithmetic is saturating (`+|`, `*|`) — a garbage token count cannot overflow the record.
- Invalid or missing stored records and failed writes return errors. A top-up ID and its credited amount are saved in the same record, so retrying after an uncertain confirmation cannot add the credit twice. An ID reused with another amount is rejected. IDs older than 90 days are rejected and pruned before a new grant, so the 128-entry history limit is not permanent; more than 128 distinct grants in a 90-day window require reconciliation.
- `chargeRun` saves the debit and a pending run target together in `n_<uid>`, advances the run checkpoint, then clears the pending marker. A retry after any failed confirmation finishes the pending update before charging another delta. The in-memory supervisor cursor is diagnostic only. Run checkpoints survive a billing-period rollover.
- A legacy worker has no stable run ID or durable charged cursor. The first upgraded meter establishes its current `.usage` as a nonbilling baseline to avoid charging usage already included in the account total. Usage that was reported but never durably charged before upgrade cannot be identified from the old aggregate record and needs operator reconciliation. The process mutex does not coordinate multiple server processes sharing one database.
- The current rollover retains the full `topup` value after `used` resets, even if some of that one-time credit was spent. Existing records do not distinguish previously spent from unspent top-up credit; remediation needs a migration and usage attribution design before this behavior can change safely.

---

*Case file grounded in the module's `//!` header and public API.*
