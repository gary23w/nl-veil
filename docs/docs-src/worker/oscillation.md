# oscillation

**File:** `src/worker/oscillation.zig`  
**Module:** `worker`  
**Description:** The worker's single gateway to neuron-db — the read/write round-trip (observe, recall, recallScored, chain, reinforce, assoc) plus the operator preamble + baseline tables. observe's argv stays deliberately flag-free: consolidation contradiction marking is the new neuron binary's own default, because an unknown flag on an older binary would be stored as fact text (capability rides the binary, never the argv).

---

## Purpose Summary

One seam for all memory traffic: every neuron-db operation the worker (and chat engine) performs goes through `Mem`, which spawns the neuron CLI binary per call with `--db` and `--max` pinned. Having a single choke point is the design — it is the place to instrument, debug, and gate memory. The file also carries the generated operator-preamble and baseline string tables (XOR-obfuscated bytes decoded at runtime; "do not hand-edit").

## Key Exports

- `Mem` — the gateway struct (`init(gpa, io, bin, db)`, optional write mutex + environ + trust flag + `stats` + `bound_ms` + `k_pin`/`hops_pin`), with:
  - `initChat(gpa, io, bin, db, environ)` — the one way every chat surface builds its Mem: the process environ (so the k/hops each recall asks for reach the CLI), trust-weighted ranking, the per-path write lock (`writeLockFor`), `CHAT_BOUND_MS` on every spawn, and the `NL_MEM_K` / `NL_MEM_HOPS` overrides (`10` and `0` reproduce the breadth every chat read ran at before).
  - writes: `observe` (single fact, normalized), `observeBatch` (many facts via one temp-pack `import` instead of a spawn per fact), `replace`, `forgetMatch` (drops only the facts containing a match; an empty match is refused), `reinforce`, `strengthen` (strength bump for facts containing a match, never mints — see below), `stance`, `mood`, `persona`.
  - reads: `recall` (single best fact), `recallScored` (top-k scored hits as raw JSON; empty on any failure, including an older binary without the verb), `coverage` (lexical presence gate from `recall --json`), `assoc` (spreading-activation neighborhood), `assocAcross` (fans over `<scope>__*` document sub-scopes), `chain`, `readPage` (insertion-order paging), `list` (full small-scope export), `scopeIds`, `factCount`, `affect`.
  - bulk: `import` / `importStats` (`ImportStats` carries the CLI's `evicted` count).
  - trust: `trustReward` (engine-driven only), `classTrust` (neutral 1.0 fail-safe), `trustDump`, `sampleClassesAlloc` (honest un-trusted class sample).
  - accounting: `WriteStats` (atomic counts of writes that landed and of each `Fail` reason — `lock`, `missing`, `pack`, `timeout`, `other` — plus lock retries and the time spent waiting to write; `line(buf)` renders the engine's per-turn "memory writes:" trace).
  - constants: `SATURATE_HOPS = 1024` (spread until the activation wave settles — bounded by convergence, not the counter), `MAX_FACTS = 20_000` (per-scope ceiling passed on every invocation).
- `writeLockFor(io, db)` — the process-wide mutex for one db path (Windows `\` read as `/`, case folded); every chat turn of a user writes one hive, so their writes queue on it.
- `cleanFactInto(buf, fact)` — fact normalization for the line-oriented store (unit-tested).
- `preambleText(buf)` / `baseText(buf)` / `drift()` — decode the generated tables; `drift()` feeds the actual on-disk db filename `Mem.run` targets.

## Dependencies

`std`, `worker/bounded.zig` (every spawn) and `worker/browser/util.zig` (`sleepMs`, the non-alertable pause) — everything else is the external neuron CLI binary (`bin` passed to `init`), with `NEURON_HOPS`/`NEURON_K` injected through a cloned environment for assoc calls.

## Usage Context

`run.zig` aliases `Mem` for the whole worker; also imported by `worker/tools.zig`, the chat engine (`worker/chat/engine.zig`, `chat/tools.zig`, `chat/overlay.zig`), `hyperspace.zig`, `continuity.zig`, `pixelrag.zig`, `ragingest.zig`, the CLI (`src/cli.zig`, `cli/exec_tool.zig`), and `src/tests.zig`.

## Notable Implementation Details

- **`--max` on every spawn:** the CLI's own default of 500 silently front-drains a scope — one absorbed book evicted the knowledge hive and then ~85% of itself; 20k holds several books while keeping the per-spawn scope parse tolerable.
- **Newlines shred facts:** the store is line-oriented, so `cleanFactInto` folds whitespace, drops notes with under 12 alphanumeric characters (line noise, not knowledge), and softens `"; "` to `", "` so quoted code stays one fact — sentence atomization on periods is the fine weave working as designed.
- **`--json` placement is load-bearing:** import's summary prints to stderr (discarded); the stored count only appears on stdout under `--json`, which must come first.
- **`stored` is not `survived`:** `importStats` exists because an import can ack thousands stored while the cap evicted most of them mid-load; callers reporting success must read `evicted`.
- **`strengthen` only re-ranks:** it runs the CLI's `strengthen <scope> <match>`, which bumps the strength of every stored fact in the scope that CONTAINS `match` and never creates one. A match under 8 bytes after trimming is refused (it would bump half the scope); the call is write-locked, best-effort (output and failure discarded) and costs one spawn. Its caller is the chat [recall overlay](#doc=worker/chat/overlay)'s Hebbian half: at turn end `Overlay.strengthenFired` strengthens each fired `[conv]` line, clipped to 48 bytes and at most 8 per turn, in the conversation's partition, so a fact the model demonstrably used ranks higher in later recall. A test in `overlay.zig` pins the one-spawn cost through `spawn_probe`, the test-build counter `Mem.exec` bumps on every spawn.
- **One spawn site, always bounded:** `Mem.exec` runs every neuron-db child through `bounded.run`, under the Mem's `bound_ms` or `NEURON_BOUND_MS` (120 s) when it names none; `importStats` (a whole document) gets `BULK_BOUND_MS` (30 min) on every Mem. `spawn_probe` counts there.
- **Writes that are not lost:** every write verb goes through `Mem.write`: the per-path lock (taken with `tryLock` and an OS-sleep backoff, never a park, because chat writes run on threads the Io runtime did not spawn), then a bounded retry while neuron-db's own single-writer lock refuses it (`LOCK_RETRIES` = 6, pauses doubling from 0.1 s to 2 s, slept with `sleepMs`), counted in `stats` by how it ended. After one write gives up on that lock, the next writes to the same db within `REFUSED_HOLD_MS` (30 s) make one attempt each instead of sitting the retries out again; a write that lands ends the window.
- `trustReward` is engine-driven only, so a mind can never inflate its own class's trust.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
