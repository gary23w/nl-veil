# rsi

**File:** `src/worker/rsi.zig`  
**Module:** `worker`  
**Description:** Recursive self-improvement for the worker — engine-owned faculties that tune the swarm's own operating parameters and strategy from measured outcomes, while the safety floor stays fixed.

---

## Purpose Summary

"Self-improvement" here means adjusting knobs, roles, and remembered process rules from measured outcomes — nothing in this file generates or applies patches to its own source code. It houses the model-capacity self-tuner (probe/name seed plus two-way adaptation from measured tool-use vs narration), the intuitive goal interpreter, the governor (proposal accept/rollback by trial confidence and token-utility), and the learning loops: multi-timescale memory distill, weakness-driven curriculum, end-of-round retrospective, trace-grounded review fork, end-of-run judge, and the role orchestrator that lets the swarm author its own division of labor each round. All of it operates on `*run.Worker`.

## Key Exports

- Capacity: `seedTier(model)` (round-0 prior — a measured `/api/show` parameter count outranks the name; unknown ⇒ assembler), `tierFromStr` (explicit tier string pins RSI off), `profileForTier` / `profileFor` (the only place per-tier budgets live), `adaptCapacity(w, round, results)` (per-round two-way adaptation).
- Intent: `interpretGoal(w, goal)` — rebuilds a terse instruction into an explicit working brief injected into every mind.
- Governance: `rsiGovernance(w, ...)`, with helpers `parseScorePct` and `scoreTrialConfidence`.
- Learning loops: `distillRsiMemory`, `updateRsiCurriculum`, `roundRetrospective` (one new self-authored playbook rule per round, injected into every mind next round), `reviewFork` (out-of-band, trace-grounded lessons/skills into the live hive scopes), `runJudge` (end-of-run; proposes durable lessons/skills into QUARANTINE scopes only — promotion is a separate reviewed step).
- Roles: `planRoles` (per-round role planner over eight archetypes — lead, implementer, reviewer, domain-learner/scout, capability-builder, inventor, analyst, outreach), `matchArchetype`, `planCast` (one-shot cast planner), `looksLikeResearch` (the research floor: such a goal must field at least one scout or it hallucinates its findings).

## Dependencies

`llm.zig` (interpreter/retrospective/judge calls), `tools.zig` (hive scopes), and `run.zig` for `Worker`, `Moment`, `BenchResult`, `Tier`, `CapacityProfile`, lanes, and helpers.

## Usage Context

Driven from `run.zig`'s round loop (capacity adaptation, governance, retrospective, role planning) and at swarm start (`seedTier`, `interpretGoal`, `planCast`); `agi.zig` calls `interpretGoal` again when an autonomous run chains to a new goal. `roundRetrospective` and `reviewFork` run in the concurrent meta group under its concurrency discipline.

## Notable Implementation Details

- The minds never control the per-tier budget — `profileForTier` is part of the engine's safety floor, and an operator-pinned tier disables adaptation entirely.
- Self-report vs trace is a load-bearing distinction: `roundRetrospective` steers the live run from self-report, `reviewFork` only mints what the round's real tool trace proves, and `runJudge` reads act rows (never monologues) and can only propose into quarantine.
- `planRoles` caps churn at half the swarm, keeps round-1's seed as a strong prior, and never strips the learning floor (≥1 scout at 4+ minds); an omitted mind keeps its prior role.
- Blueprint-file ownership matching is word-bounded and requires exactly one named file, so a mere mention cannot steal a file from the mind the plan assigned it to.
- The prose-tolerant JSON fallback (`textField`, unit-tested) exists because weak models truncate and wrap their JSON.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
