# oscillation

**File:** `src/worker/oscillation.zig`  
**Module:** `worker`  
**Description:** The worker's single gateway to neuron-db — the read/write round-trip (observe, recall, chain, reinforce, assoc) plus the operator preamble + baseline tables.

---

## Purpose Summary

One seam for all memory traffic: every neuron-db operation the worker (and chat engine) performs goes through `Mem`, which spawns the neuron CLI binary per call with `--db` and `--max` pinned. Having a single choke point is the design — it is the place to instrument, debug, and gate memory. The file also carries the generated operator-preamble and baseline string tables (XOR-obfuscated bytes decoded at runtime; "do not hand-edit").

## Key Exports

- `Mem` — the gateway struct (`init(gpa, io, bin, db)`, optional write mutex + environ + trust flag), with:
  - writes: `observe` (single fact, normalized), `observeBatch` (many facts via one temp-pack `import` instead of a spawn per fact), `replace`, `reinforce`, `stance`, `mood`, `persona`.
  - reads: `recall` (single best fact), `coverage` (lexical presence gate from `recall --json`), `assoc` (spreading-activation neighborhood), `assocAcross` (fans over `<scope>__*` document sub-scopes), `chain`, `readPage` (insertion-order paging), `list` (full small-scope export), `scopeIds`, `factCount`, `affect`.
  - bulk: `import` / `importStats` (`ImportStats` carries the CLI's `evicted` count).
  - trust: `trustReward` (engine-driven only), `classTrust` (neutral 1.0 fail-safe), `trustDump`, `sampleClassesAlloc` (honest un-trusted class sample).
  - constants: `SATURATE_HOPS = 1024` (spread until the activation wave settles — bounded by convergence, not the counter), `MAX_FACTS = 20_000` (per-scope ceiling passed on every invocation).
- `cleanFactInto(buf, fact)` — fact normalization for the line-oriented store (unit-tested).
- `preambleText(buf)` / `baseText(buf)` / `drift()` — decode the generated tables; `drift()` feeds the actual on-disk db filename `Mem.run` targets.

## Dependencies

Only `std` — everything else is the external neuron CLI binary (`bin` passed to `init`) invoked via `std.process.run`, with `NEURON_HOPS`/`NEURON_K` injected through a cloned environment for assoc calls.

## Usage Context

`run.zig` aliases `Mem` for the whole worker; also imported by `worker/tools.zig`, the chat engine (`worker/chat/engine.zig`, `chat/tools.zig`), `hyperspace.zig`, `pixelrag.zig`, `ragingest.zig`, the CLI (`src/cli.zig`, `cli/exec_tool.zig`), and `src/tests.zig`.

## Notable Implementation Details

- **`--max` on every spawn:** the CLI's own default of 500 silently front-drains a scope — one absorbed book evicted the knowledge hive and then ~85% of itself; 20k holds several books while keeping the per-spawn scope parse tolerable.
- **Newlines shred facts:** the store is line-oriented, so `cleanFactInto` folds whitespace, drops notes with under 12 alphanumeric characters (line noise, not knowledge), and softens `"; "` to `", "` so quoted code stays one fact — sentence atomization on periods is the fine weave working as designed.
- **`--json` placement is load-bearing:** import's summary prints to stderr (discarded); the stored count only appears on stdout under `--json`, which must come first.
- **`stored` is not `survived`:** `importStats` exists because an import can ack thousands stored while the cap evicted most of them mid-load; callers reporting success must read `evicted`.
- Writers serialize through the optional shared mutex; `trustReward` is engine-driven only, so a mind can never inflate its own class's trust.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
