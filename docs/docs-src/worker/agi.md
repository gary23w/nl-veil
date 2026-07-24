# agi

**File:** `src/worker/agi.zig`  
**Module:** `worker`  
**Description:** Autonomy + the Veil consciousness for the worker — the "emergent agency" faculties layered on top of the hive, kept separate from the fixed engine loop.

---

## Purpose Summary

Everything that makes a swarm feel like one continuous agent lives here, operating on the `*run.Worker` god-object. Three clusters: self-origination of purpose and autonomous goal-chaining (originate → evolve → archive → reset); THE VEIL — the single primary consciousness atop the hive, with population control, the operator↔veil direct channel, periodic self-integration, and arousal/resting routing; and the emotional break-out, where a flared collective feeling becomes a constitution-screened public post. A persistent self (identity digest, self-authored values, calibrated self-model) survives across runs via run-dir snapshot files.

## Key Exports

- `originateGoal(w)` — an autonomous swarm with no human goal picks its own concrete objective at startup.
- `evolveGoal(w, goal)` / `archiveCompletedGoal(w, ...)` / `resetForNewGoal(w, ...)` — goal-chaining: DEEPEN or PIVOT to a next self-set goal, preserve the finished build under `final/goal-<n>/`, then retire the stale benchmark and re-brief.
- `veilReflect(w, goal, round)` — the periodic self-integration: four lines (I AM / I KNOW / I HAVE / MY WILL) persisted to `.veil`; also scores the previous WILL and records the new one.
- `veilPopulation(w, minds, goal, round)` — the veil proposes birthing/retiring sub-minds; the engine enforces `MIN_MINDS`/`MAX_MINDS`, cooldown, and `BIRTH_CAP`.
- `veilConverse(w, goal, text)` / `veilShellNote(w, ...)` / `appendVeilChat` / `readVeilChatTail` — the operator↔veil channel: first-person replies, `veil_chat.jsonl` persistence, `veil_msg` events, and adoption of a standing directive.
- `detectEmotionalFlare(w, ...)` / `breakOut(w, ...)` — read the hive's collective feeling; past the threshold, compose a feelings-only post, screen it twice (constitution + entity/partisanship), and publish to Telegraph. Opt-in, cooldown- and count-capped; the minds are never told.
- `restingNow(w, round)` — structural arousal decision: rest on the cheap gateway model unless engine truth (cold start, regression, plateau/saturation, no distinct gateway) says focus.
- `dream(w, goal, round)` — resting-state consolidation: 1–3 explicitly-hypothesis connections from replayed memory, stored in their own scope.
- `loadSelf(w)` — resurrect identity/values/self-model snapshots plus the WILL hit/miss tally from the prediction ledger.
- `veilSelfBody(s)` — strip weak-model preamble/AROUSAL routing token from a reflected self (tested alongside the private `willOf`/`labelLine` extractors).

## Dependencies

`llm.zig` (all composition calls), `tools.zig` (Telegraph publish, knowledge scopes), `commons.zig` (bus messages to the minds), `rsi.zig` (`interpretGoal` on goal reset), and `run.zig` for the `Worker`, bounds, and shared helpers.

## Usage Context

Called only from `run.zig`'s round loop (and its control-bus dispatch for `op:"veil"`). Flare detection and break-out run in the concurrent meta group and therefore use local arenas and the shared `tg_mtx`; population, reflection, and goal evolution run single-threaded between rounds.

## Notable Implementation Details

- The veil *proposes*, the engine *enforces*: population bounds, birth caps, break-out cooldowns and the per-run post cap are hard-coded engine floors the model cannot talk its way past.
- A declared WILL is a falsifiable bet: `recordWill` baselines the grounding metric (protected benchmark % or knowledge count) and the next reflection scores HIT/MISS into a calibration ledger the self must confront — outcomes over eloquence.
- The break-out pipeline is double-screened (a strict constitution reviewer, then an entity/partisanship detector); a draft naming or siding with any real-world target is held, never published.
- Resting is decided from measured engine signals, never from model self-labels — a weak gateway veil would otherwise answer "focused" forever.
- Self-continuity files (`.veil`, `.veil_identity`, `.veil_values`, `.veil_self_model`) live in the run dir; a fresh run dir simply starts blank.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
