# bounded

**File:** `src/worker/bounded.zig`  
**Module:** `worker`  
**Description:** A child process run under a bound that holds on every platform, with both of its streams kept: one deadline for the whole run, the child's whole tree killed at it, and on Windows the pending pipe reads cancelled before the reader is torn down.

---

## Purpose Summary

Zig 0.16's `std.process.run` `.timeout` is no bound on Windows for a child that prints nothing. Its `MultiReader.fill` returns `error.Timeout` on time, but run's deferred `multi_reader.deinit()` runs before its deferred `child.kill()`, and `Io.Threaded`'s Windows `batchCancel` waits for an APC (an infinite alertable `NtDelayExecution`) before it cancels the pending reads. A child that still holds its pipes and prints nothing delivers no APC, so deinit waits for it to exit on its own, and only then is it killed. Measured on 2026-10-14: a 1 s `.timeout` on a silent `cmd /C "ping -n 6 127.0.0.1 >NUL"` came back after 5099 ms; a child printing a line a second came back on time. The `.duration` form also restarts at every fill, so where it works it bounds the silence between reads, not the run. Its output limits hang outright on Windows: past `stdout_limit` run returns `StreamTooLong` with stdout's next read only queued (`Batch.addAt` issues it at the next await), so deinit waits on stderr's read alone, and with stderr silent the child blocks forever on its full stdout pipe (measured: a looping `echo` sat there 8 minutes until killed by hand).

`run` reads both pipes itself under ONE deadline (`Io.Timeout.toDeadline`). At the deadline, or past an output limit, it kills the child with everything it started (`killTree`), and on Windows it calls `CancelIoEx` on both pipe handles before the reader's deinit, so the batch cancel finds the APCs it waits for. POSIX's batch cancel only frees poll storage, so there the change is the tree kill and the single deadline.

## Key Exports

- `run(gpa, io, Options) Result` — never fails; how the run ended is `Result.end`
- `Options` — `argv`, `cwd`, `environ_map` (null = this process's own), `bound_ms` (spawn to exit, not extended by output), `stdout_limit`, `stderr_limit`, `stderr_tail` (keep stderr's tail instead of ending the run: past 4x the limit it is cut back to its last `stderr_limit` bytes), and `head_tail` (keep the first and last `limit` bytes of both streams instead, so neither ever ends the run; overrides `stderr_tail`)
- `End` — `exited`, `signal`, `killed` (still running at the bound), `overflow` (printed past a limit, what `StreamTooLong` was; never under `head_tail`), `unread` (output not readable or exit not collected), `unstarted` (the spawn failed)
- `Result` — `end`, `code`, `stdout`, `stderr` (gpa-owned), `err` (the spawn's own error for `.unstarted`, so `deps.isSpawnMissing` still tells a missing program from a failing one), plus `ok()`, `exited()` (the code, or null), `finished()` (exit or signal: exactly the runs `std.process.run` returned a `RunResult` for), `why()`, `deinit(gpa)`
- `killTree(io, *Child)` — `taskkill /F /T` on Windows (cmd.exe never execs, so a shell's grandchild outlives a kill of the shell); the process group on POSIX, then the child itself
- `spawnGuarded(io, argv, deadline_ms)` — spawn with no pipes and terminate by handle at the deadline from a watchdog thread (moved here from `tools.zig`, which aliases it); `killTree`'s taskkill runs through it
- `seam.cap_ms` (tests only) — caps every bound, so a test can drive a caller whose real bound is minutes to its cut in a second

## Dependencies

- `std`, `builtin` — no other repo modules (one test imports `deps.zig`)
- `kernel32` — `CancelIoEx`, `GetProcessId`, `TerminateProcess`, `Sleep`

## Usage Context

- `worker/run.zig` — `runDeclaredChecks` (240 s per VERIFY row, `head_tail`), `probeRowExecutes` (25 s), `curlCode` (8 s), `pySalvageCheck` (15 s); `declaredSmoke` reaps its boot through `killTree`
- `worker/tools.zig` — `runProbe` (poll kind=command, the call's remaining `timeout_s`), the python edit gate `pyCompileError` (15 s), `nodeCheckOnce` (15 s), `zigAstCheckError` (20 s); `spawnGuarded` for curl fetches and `taskkill`
- `worker/deps.zig` — `versionOf`, `onPath`, `probeDirect` (5 s each)
- `worker/toolchain.zig` — `bootstrap` installs (360 s each, `head_tail`)

Registered directly in `src/tests.zig`.

## Notable Implementation Details

- Output is COPIED out of the read buffers, never `toOwnedSlice`d: on Windows a run cut at its bound still has overlapped reads aimed at those buffers, and only the reader's deinit drains them before freeing (measured with a quarantine allocator in a `tools.zig` poll test).
- A limit ends the run as `.overflow` and kills the tree, as `StreamTooLong` did. Callers that showed "did not finish (spawn failed or exceeded Ns)" for every failure now name the actual end: still running at the bound, printed over the limit, or could not be run.
- `head_tail` keeps a run going to its exit however much it prints. Past its limit a stream's first `limit` bytes are set aside, and what follows is cut back to its last `limit` bytes each time it passes 4x that. The result is the head, a `[... N bytes not kept ...]` line, and the tail, each side cut back to whole lines where a line ends within 512 bytes of the cut. A stream that printed no more than 2x its limit is kept whole. VERIFY rows (`runDeclaredChecks`, 48 KB) and dependency installs (`toolchain.bootstrap`, 32 KB) use it. Stopped at the limit, a passing `pytest -v` or verbose `cargo test` past 48 KB was scored as a failed row, and a chatty `npm install` was killed mid-install. Both ends rather than the tail alone, because of what reads a failing row's output: `errorHeaders` lists the first 12 lines that start with "error" and `checkDiag` starts at the first line containing "error", and a compiler's root cause is at the top; a test runner's summary, and `checkDiag`'s fallback (the last 700 bytes when no line says "error"), are at the bottom. The install note reads the last 300 bytes.
- POSIX children are spawned as process-group leaders (`pgid = 0`) so the tree kill reaches nested shells (dash does not exec a nested `sh -c`). The cost, accepted: a terminal's Ctrl-C no longer reaches the child directly.
- Not bounded: a child that closes both pipes and keeps running is waited for, as `std.process.run` waited for it.
- Tests (real shells): a child silent on its pipes is cut at 1 s with its grandchild dead and no natural-end marker; a child whose pipes are held by an orphan `taskkill /T` cannot reach (`start /B`) still ends at its bound (Windows, the `CancelIoEx` proof); a child printing every second is cut at a 3 s deadline; a run inside its bound keeps both streams and its exit code; stdout past its limit is an overflow while a stderr tail never is; under `head_tail`, ~36 KB on each stream against 1 KB limits exits with its own code, keeps both ends with the cut between whole lines, and what it kept plus the marker's count equals what the script printed, while ~1.4 KB against 1 KB is kept byte for byte as an uncapped run keeps it; a missing program reads as `.unstarted` with a spawn-missing error. `run.zig` drives `runDeclaredChecks` and `probeRowExecutes` through a silently hanging row with `seam.cap_ms`, and `runDeclaredChecks` through rows printing ~180 KB that pass and a ~300 KB failing row whose feedback names a failing point from each end. `toolchain.zig` drives `bootstrap` with a fake `npm` printing ~200 KB on each stream. `tools.zig` checks the python gate's verdicts through the bounded run.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
