# toolperf

**File:** `src/worker/chat/toolperf.zig`  
**Module:** `worker/chat`  
**Description:** Per-machine tool-performance learning — dynamic and emergent, with no hardcoded expectations.

---

## Purpose Summary

The engine times every tool call and tallies (name, ok/fail, latency). At turn exit those tallies merge into a small persistent aggregate at `{data}/.tool_perf.json` — one row per tool with running call/fail counts and an EWMA latency (recent behavior dominates). At turn start the engine asks `digest()` for a compact line naming only the *notable* tools (slow or flaky, with enough samples) and injects it into the prompt, so the agent plans around how tools actually behave on this machine instead of re-learning it every run. This is the substrate's no-hardcoded-use-cases rule applied to tool latency/reliability: the guidance is grown from live signals, never baked in.

## Key Exports

- `MAX_TOOLS` (48) — distinct tool names tracked.
- `Acc` — the per-turn, fixed-size, stack-lived accumulator: `record(name, ok, outcome_ok, ms)` after each executed tool (skip dedup/budget guards — they never ran the tool), `slice()` for the trust-reward pass at turn exit. `AccRow` aliases its row type.
- `ledger(acc, gpa) ?[]u8` — a one-line record of what this turn actually ran ("browser_click x40 ok, run_python x41 (3 failed)"); null when nothing ran.
- `merge(io, gpa, data, acc)` — fold the turn into the persistent aggregate (load → EWMA-update → write); best-effort, never fatal.
- `belt(gpa, io, data, trust_line) ?[]u8` — the positive half: a per-step line ranking tools reliable-first by lived *outcome* success on this machine, with an optional trust line appended verbatim; null when too little has been learned to rank (fewer than two rankable tools).
- `digest(gpa, io, data) ?[]u8` — the warning half: the notable slow/flaky tools, worst-first, deterministic ordering so the line is stable when the data hasn't moved; capped at 8 tools.

## Dependencies

- `std` only.

## Usage Context

Driven by the chat engine's tool loop (record → merge at turn exit → digest/belt injection); also imported by `src/cli.zig`. Compiled into the suite via `src/tests.zig`.

## Notable Implementation Details

- Two distinct failure channels: `fails` is *tool* health (the call itself errored — engine refusal, transport failure); `bad` is *outcome* quality (the tool ran fine but its result was a failure, e.g. exit != 0 or `"ok":false`). A run_python returning exit=1 is a healthy tool with a failed outcome — the distinction the belt ranking runs on.
- Thresholds: EWMA alpha 0.3; notable = averaging over 3000 ms or failing at least 25% of the time, with at least 3 samples (avoid noise); a corrupt or huge aggregate file is ignored (64 KiB cap).
- `ledger` exists for the post-answer critique, which is asked to catch claims contradicting what the tools actually returned — but was never shown what they returned. Guessing from the answer alone, it repeatedly told users the assistant *could not* do things this ledger proves it had just done (denying a browser it had driven 31 times, Python it had run 41 times). A confident false correction is worse than no correction, so the critique now gets the record instead of imagining it.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
