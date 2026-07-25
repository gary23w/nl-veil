# The SELF lane (H10) — design, not switched on

**Status: DESIGN ONLY. Nothing here is wired. Enabling it is the owner's decision.**

This is the Ring 2 item from `HORIZON.md`: letting `veil cast` treat *this repo* as its work tree,
so the engine's existing self-improvement faculties operate on the app that runs them. The engine
already has every part except the aim: goal-declared acceptance rows (`VERIFY:` / `SMOKE:` /
`PROBE:` in run.zig), a governor that accepts or rolls back proposals on trial confidence, playbooks
that compound through `set_directive`, and cross-run lineage. None of it has ever pointed here.

Written down now because the design is the cheap part and the safety floor is the part worth
arguing about before any of it exists.

## Why it is worth doing

Every increment in this ledger followed the same loop: read a signal, pick one thing, change it,
run the oracle, record what happened. That loop is mechanical enough to delegate and has produced
~48 entries of real fixes. The bottleneck is not judgement — it is that a human or an external
agent has to be driving. A SELF lane makes the loop resident.

## Why it is dangerous, stated plainly

An agent editing the repo that defines its own gates can, in principle, edit the gates. Everything
below exists to make that specific move impossible rather than merely discouraged.

## The safety floor (all of it, or none of it)

1. **The oracle is out of reach.** A SELF cast may not modify `scripts/check.ps1`,
   `scripts/check.sh`, `.github/workflows/`, `src/tests.zig`, `desk/src/tests.zig`, or anything
   under `harness/`. Enforced by a path deny-list in the writer, not by instruction — an agent that
   can edit its own acceptance criteria has no acceptance criteria. Harness improvements stay a
   human/external-worker job, which is a real cost and the right one.
2. **Nothing merges itself.** Work lands on a branch (`self/<lineage>/<n>`) and stops. A human
   opens, reads and merges the PR. No push to `main`, ever.
3. **Green is necessary, not sufficient.** The cast's acceptance rows run the REAL oracle
   (`sh scripts/check.sh`), and a red result discards the increment rather than retrying against a
   weakened test. The governor already does accept/rollback; this points it at the oracle's exit
   code.
4. **One increment per cast.** The `/grow` contract already says this. A cast that touches more
   than N files or more than one ledger item stops and reports instead of continuing.
5. **The ledger is append-only for the swarm too.** A SELF cast may add an entry; it may not edit
   or delete an existing one. Rewriting the record of what happened is the failure this whole
   harness exists to prevent.
6. **Standing identity, bounded memory.** `lineage: nl-veil-self` so lessons compound across casts
   — with the same rule as the ledger: it may add, not rewrite.

## Shape of the work, if it is ever approved

- A `--self` flag on `veil cast` that sets the work tree to the repo root, applies the deny-list,
  and forces the branch-only policy. Deliberately NOT the default and NOT reachable from the web UI.
- Acceptance rows in the goal: `VERIFY: sh scripts/check.sh`, plus `PROBE:` rows for the scan
  signals a given increment should leave clean.
- A dry-run mode first (`--self --plan-only`) that produces the diff and the ledger entry and
  writes nothing, so the first several runs are read-only and reviewable.

## What I would want to see before switching it on

The dry-run mode, exercised on ten real increments, with a human judging whether the picks and the
diffs were ones they would have accepted. If the answer is "mostly, but I would not have merged
three of them", the floor is not ready.

## Honest assessment

The mechanism is straightforward; the judgement is not. Everything genuinely valuable this session
came from noticing that two things which should agree had stopped agreeing — and noticing that took
reading comments, measuring the right operation, and being willing to conclude "clean, nothing to
fix". Those are exactly the moves a metric-chasing loop does worst. A SELF lane will produce
volume. Whether it produces *this* is untested, and the dry-run above is how you would find out
before it can cost anything.
