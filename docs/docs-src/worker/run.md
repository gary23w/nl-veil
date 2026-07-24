# run

**File:** `src/worker/run.zig`  
**Module:** `worker`  
**Description:** The veil worker — one hive process in Zig, spawned as `veil worker <run_dir> <neuron_bin> <model>`, running the per-round, per-mind tick loop and emitting the NDJSON event contract.

---

## Purpose Summary

The worker process behind every swarm. It reads `<run_dir>/swarm.json` (provider, model, goal, minds, minutes, …), records its pid in `worker.pid`, then loops: each round every mind recalls what it knows from neuron-db, has a "moment" (one real LLM call, or a mock when there is no key), observes a new fact, and forms a stance. Events (`started` / `round` / `tick` / `growth` / `board` / `stopped`) stream to `<run_dir>/events.jsonl` with a monotonic `seq` — exactly what the SSE stream and web UI render. Each round it drains operator input from `control.jsonl` (say / broadcast / set_goal / stop) and honours the `STOP` sentinel and the per-swarm minutes timer. A worker is ~1–5 MB resident; per-tick latency is dominated by the model, not the host.

## Key Exports

- `run(gpa, io, environ, run_dir, neuron_bin, cli_model)` — the process entry point.
- `Worker` — the run-state god-object that `agi.zig` and `rsi.zig` operate on (emitters, memory handle, fitness trajectory, veil state, budgets).
- `MindState` / `GuardRec` — per-mind state incl. the tool-loop guard (identical call+result repeats), persona, lane, scout flag.
- `LANES` / `SCOUT_LANE` — pre-assigned work lanes so parallel minds diverge from moment 1; the scout lane learns instead of building.
- `Moment`, `BenchResult`, `FitnessSource`/`fitnessSource` — one tick's outcome and how a round is graded (host tests / doc mass / declared tests / none).
- `Tier`, `CapacityProfile`, `TEMP_FLOOR`, `Schema`, `modeGate`, `govLevelFrom` — the capacity/governor knobs rsi.zig tunes.
- `MIN_MINDS` / `MAX_MINDS` / `BIRTH_CAP` — the population bounds enforced against the veil's proposals.
- Shared helpers used by the sibling faculties: `clip`/`clipTail`, `buildTree`, `buildState`, `planProject`, `personaFor`, `copyBuild`, `escA`, `jsonSlice`, and more.

## Dependencies

`llm.zig` (chat calls), `oscillation.zig` (`Mem`, the neuron-db gateway), `tools.zig`, `rsi.zig`, `agi.zig`, `commons.zig` (bus messages), `hyperspace.zig`, `bufedit.zig`, `crawl.zig`, `writer.zig`, `toolchain.zig`, `lineage.zig`, `ragmirror.zig`, `chat/context.zig`, plus the shared `modelcfg` module.

## Usage Context

Spawned by the server (`veil worker` subcommand dispatched in `src/main.zig`); the desk and web UI only ever see its run-dir files and event stream. `agi.zig` (veil consciousness) and `rsi.zig` (self-tuning) are layered faculties that receive `*run.Worker`.

## Notable Implementation Details

- **Goal-declared acceptance:** a goal may carry its own acceptance interface — `VERIFY: <shell command>` rows run verbatim as the benchmark (any toolchain), `SMOKE: <command>` declares how to boot the deliverable, and `PROBE: <url>` rows must answer 2xx/3xx once booted. Parsed into `Worker.checks_str` / `smoke_cmd` / `probes_str` (unit-tested).
- The manifest carries the run's whole shape: mode, benchmark/corpus, `lineage` (persistent per-user neuron-db so re-casts compound memory), `autonomous`, `breakout`, gateway model, `cast`, and declared `files` (adopted verbatim as the blueprint).
- Fitness is measured, never self-reported: `BenchResult` + `fitnessSource` pick the grading source, and the trajectory (best/flat/regress/stale round counters) drives phase decisions.
- The NDJSON `seq` is the replay contract — consumers resume from a cursor, so events are append-only and monotonic.
- This file is 10k+ lines because the engine floor lives here; the "AI" faculties are deliberately split out into `agi.zig`/`rsi.zig`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
