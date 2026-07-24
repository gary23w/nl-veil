# lineage

**File:** `src/worker/lineage.zig`  
**Module:** `worker`  
**Description:** Cross-run swarm memory — when a cast declares `lineage: "<id>"`, its neuron-db becomes a stable per-user store (`{userRoot}/_lineage/<slug>/mind.sqlite`) that every later cast with the same id reopens, so knowledge compounds run over run.

---

## Purpose Summary

A swarm's whole brain is normally `{run_dir}/mind.sqlite` — born and destroyed with the run dir, which is why a swarm doesn't visibly "get better over time": kill a cast, re-cast the same goal, and the second swarm re-learns everything the first one knew. A lineage keys the db to a stable identity instead, so knowledge, the self-authored playbook, the skill library, and the learned trust ledger all persist across separate casts. It generalizes the pattern a scheduled task already uses (one memory partition shared across its runs) to any cast.

## Key Exports

- `slug(id, buf)` — sanitize a user-chosen lineage id into a filesystem-safe slug (lowercased, `[a-z0-9-_]`, runs collapsed to `-`, clipped; `"default"` when nothing survives)
- `userRootOf(run_dir)` — the per-user root a run_dir belongs to (peels the `/_chat/…` or `/_sched/…` build tail; anything else falls back to the run_dir's parent)
- `dbPath(gpa, io, run_dir, lineage_id)` — resolve the persistent neuron-db path, creating its directory; null for an empty id (caller keeps the per-run brain)
- `exists(io, gpa, db)` — has a prior cast populated this store? Lets the engine tell a mind "you INHERIT the memory of N prior runs" vs "you are the first run"

## Dependencies

- `std` only.

## Usage Context

Imported by `worker/run.zig` (and `src/tests.zig`). The header ties it to the run wiring: run.zig owns `{run_dir}/mind.sqlite` today; a cast that declares a lineage swaps in the stable path this module resolves.

## Notable Implementation Details

- Sharing the WHOLE db is safe, not just the durable scopes: the run-local scopes (PLAN/STATE) are replace-written each run and the per-round write ledger is file-based under run_dir, so they never accumulate cross-run garbage — the scopes that should persist are exactly the ones that do.
- Pack/corpus re-seeding stays idempotent because import runs with `--dedup`.
- v1 constraint: one active cast per lineage at a time (two concurrent same-lineage casts would interleave their PLAN/STATE). The neuron-db write lock keeps the store consistent; the caster is expected not to launch overlapping runs.
- The tests pin the whole point: two different run dirs under the same user and lineage resolve to the SAME `_lineage/<slug>/mind.sqlite`; an empty/blank id opts out with null.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
