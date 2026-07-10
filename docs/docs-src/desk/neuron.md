# neuron

**File:** `desk/src/neuron.zig`  
**Module:** `desk`  
**Description:** A minimal, degrade-to-no-op client wrapping the external `neuron` CLI against a chat-local sqlite db, giving the veil-desk chat a persistent hippocampus (observe / recall / reinforce / strengthen / forget / chain).

---

## Purpose Summary

Bridges the native desktop chat to neuron-db by spawning the same `neuron` binary the swarm minds use, one subprocess per operation, against a chat-local sqlite file. It lets the chat OBSERVE conversation turns and cast findings as neurons, trust-weighted-RECALL the relevant ones into the next prompt, and LEARN from outcomes via Hebbian/strengthen-only plasticity. Every operation is fail-open: if the binary or db path is missing or any call errors, it silently no-ops so the chat behaves exactly as it did before neuron-db existed.

## Key Exports

- `Db` — the client struct (fields: `gpa`, `io`, `bin`, `db`); empty `bin`/`db` disables all ops. Holds the private `run()` helper that assembles `[bin, "--db", db, ...args]` and execs it.
- `Db.enabled` — true only when both `bin` and `db` are non-empty.
- `Db.observe(scope, text)` — store one fact; trims, requires ≥3 chars, caps text at 1400 bytes, runs `observe`.
- `Db.recall(scope, query, out)` — trust-weighted spreading-activation recall via `--trust assoc`; requires a ≥3-char trimmed query, caps query at 400, copies result into caller's `out` buffer, treats <24-byte or `(`-prefixed replies as a miss (empty slice).
- `Db.reinforce(scope, topic, feeling)` — Hebbian plasticity; runs `reinforce`, defaults `feeling` to "useful", requires a ≥3-char topic, caps topic at 200. CAN mint a fact.
- `Db.strengthen(scope, match)` — strengthen-only plasticity; bumps facts whose text CONTAINS `match`, never mints or rewrites; requires a ≥3-char match, caps at 300 with UTF-8 codepoint-boundary backwalk.
- `Db.forget(scope, match)` — delete facts containing `match`; ≥3-char guard prevents whole-scope wipe; caps at 120.
- `Db.dump(scope)` — returns the CLI `export` dump (allocated, caller frees) or null; null when scope is empty.
- `Db.statsScope(scope)` — parses `stats` output into `ScopeStats{facts, created_ms, updated_ms}`; null when scope is empty.
- `Db.forgetAll(scope)` — deliberately wipes a whole scope (runs `forget` with no match), bypassing forget()'s guard; curator archival only.
- `Db.chain(scope, start, relation, out)` — deterministic multi-hop relational traversal via `chain`; requires non-empty `start` and `relation`, returns endpoint into `out`, empty on a break.
- `findBin(gpa, io)` — probes a fixed candidate list of paths near the app cwd (bin/neuron.exe, bin/neuron, neuron.exe, ./neuron.exe, ../bin/neuron.exe, ../bin/neuron) for the neuron binary, returns an owned dupe or "".

## Dependencies

- std (std.process.run, std.mem, std.fmt, std.ArrayListUnmanaged)
- std.Io (Io type threaded through; Io.Dir.cwd().statFile in findBin)
- log.zig (log.trace on every entry point)
- external: the `neuron` CLI binary (located via findBin) + a chat-local neuron-db sqlite file passed as `--db`

## Usage Context

Constructed and held by the veil-desk desktop chat as its HIPPOCAMPUS. At startup the chat calls `findBin` to locate the `neuron` binary and points `db` at a chat-local sqlite; if either is absent the client stays inert. During a conversation the chat calls `observe` on turns and cast findings, `recall` to inject relevant facts into the next prompt, `reinforce`/`strengthen` to learn from successful outcomes, `forget` on a user/AI FORGET: directive, and `dump`/`statsScope`/`forgetAll` for a background curator that archives scopes. The doc-comments map neuron-db to the app's cognition model: belief→recall, learning→reinforce/strengthen (plasticity), reasoning→chain (and, by the broader project framing, perception→observe).

## Notable Implementation Details

Integration seam is a SUBPROCESS PER OPERATION, not an in-process library: `run()` builds argv `[bin, --db, db, ...]`, calls `std.process.run` with a 256 KiB `stdout_limit`, frees stderr, and returns stdout only when the process term is `.exited` (any non-`.exited` term → null). This is a blocking exec on the calling thread. IMPORTANT correction: run() does NOT filter on the exit *code* — a process that exits `.exited` with a non-zero status still returns its stdout; only an abnormal term (signal/kill/stopped, i.e. term != `.exited`), a spawn/run error, an alloc failure, or a disabled (empty bin/db) client collapse to null. FAIL-OPEN is the whole design contract: those failure paths plus CLI \"miss\" messages all collapse to null/empty/void so the chat never changes behavior when neuron-db is unavailable (a non-zero-exit process matters only insofar as its empty/parenthetical output then trips the recall/chain miss-heuristic). Two output styles: `observe/reinforce/strengthen/forget/forgetAll` allocate and immediately free their own stdout (statsScope similarly allocates, parses, then frees); `recall/chain` instead memcpy (capped at `out.len`) into a CALLER-OWNED fixed buffer and return a slice into it, while `dump` hands back the raw allocation for the caller to free. Miss detection is a heuristic on the CLI's human-readable output: a reply that is short (recall <24 bytes; chain 0 bytes) or begins with `(` (e.g. \"(the hive knows nothing…)\", \"(chain broke after …)\") is treated as empty so no noise is injected. Per-op length caps differ (observe 1400 / recall-query 400 / reinforce-topic 200 / strengthen 300 / forget 120), and each of THOSE five ops enforces a ≥3-char trimmed-input floor; the remaining ops (chain, dump, statsScope, forgetAll) only guard against a completely empty arg (len == 0), not a 3-char floor. Two subtle guards: `strengthen` backwalks the 300-byte cut over UTF-8 continuation bytes (`(b & 0xC0) == 0x80`) so a truncated key never becomes a half-codepoint that matches nothing; and `forget`'s ≥3-char guard exists specifically so an empty match can't wipe an entire scope — which is exactly what `forgetAll` does on purpose, making them deliberately separate entry points. `recall` prepends `--trust` before `assoc` for trust-weighted ranking and is documented to degrade to plain assoc on an older binary. `statsScope` tokenizes on whitespace, only advances on a `facts:`/`created:`/`updated:` label token, and dispatches purely on that token's first char (`f`/`c`/else → facts/created/updated). Note the file's own top doc-comment calls it `neurondb.zig` though the file is `neuron.zig`.

---

*Documentation generated for nl-veil — desk/neuron.zig source analysis.*
