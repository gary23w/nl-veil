# Horizon — how this app grows

The app's long arc is that it becomes its own best worker. The harness gets there in rings, each
ring grown out of the last by ordinary `/grow` increments — never by a big-bang framework.

## Ring 0 — external workers (seeded, live now)

AI workers prompted "grow / fix / upgrade" follow `.claude/skills/grow/SKILL.md`:
sense (`scripts/check.ps1 -Scan`) → pick one increment → verify (`scripts/check.ps1`) → record
(`harness/LEDGER.md`) → ratchet the harness. The ledger is the only memory workers share, so every
session ends by writing to it. The oracle is the only definition of done, so every session ends
green or honestly red.

## Ring 1 — the app grows sensors for itself

Today the engine's rich runtime ledgers (per-model LLM metrics, tool timings, scheduler outcome
ledger, fitness blocks) describe *deliverable runs*, all under gitignored `data/`. Ring 1 turns
those inward and outward:

- A `veil doctor --growth` style report that folds runtime signals (error streaks, slow tools,
  failing schedules, model fail-rates) into worker-readable health — so SENSE reads the *running
  app*, not just the source tree.
- More `-Scan` signals as they earn their keep: bench regressions on engine hot paths, hermetic
  desk tests, docs-mirror drift, version-stamp drift (the seed already checks the last two).
- A tiny benchmark harness for the engine's own hot paths, so "faster" is a verifiable claim.

## Ring 2 — self-hosting: the app is its own deliverable

The engine already has everything a self-directed builder needs — goal-declared acceptance rows
(`VERIFY:` / `SMOKE:` / `PROBE:` in run.zig), a governor that accepts or rolls back proposals,
playbooks, and cross-run lineage. It just never points them at this repo. Ring 2 closes the loop:

- A SELF lane: `veil cast` accepts this repo as the work tree, with acceptance rows that run the
  real oracle (`zig build test`, `scripts/check.ps1`). The engine stays the floor (gates, rollback,
  audit); the minds are the content. Work lands as ordinary commits a human can review.
- A standing lineage id (`nl-veil-self`) so what the swarm learns about growing this codebase
  compounds across casts instead of evaporating.
- The retrospective faculty appends to `harness/LEDGER.md` like any other worker — one memory,
  humans, external AIs, and the resident swarm all writing to it.

## Principles

- **Grown, not built.** Every ring arrives as small verified increments. If a harness piece isn't
  earning its keep, prune it — the ledger records why.
- **Signals over curation.** Nobody hand-writes the backlog. Open items come from scan signals,
  red gates, runtime ledgers, and recorded discoveries. No hardcoded use-cases; behavior emerges
  from live signals.
- **One memory.** All workers — human, external AI, resident swarm — share LEDGER.md. If it isn't
  in the ledger, it didn't happen.
- **The oracle is the boundary.** Anything may propose; only green merges. The engine owns the
  floor, intelligence owns the content.
