# vitals

**File:** `src/worker/vitals.zig`  
**Module:** `worker`  
**Description:** The app's own resource readings: sampled every 5 s, logged once a window and immediately on a spike, and served at `GET /api/v1/vitals`.

---

## Purpose Summary

The 2026-10-11 lag hunt was done by hand with Windows performance counters. Every answer it found was a number the app could have reported itself: Defender re-reading the training-set files after every model call (see dataset's rolling parts), and every thread committing a 16 MiB stack up front (see threads). vitals makes the app report those numbers.

A sample holds this process's commit charge, working set, thread and handle counts and disk bytes; the machine's commit charge against its limit and its free RAM; and Windows Defender's read bytes. A logged line also counts threads by name: `veil:<role>` for threads started through threads.zig, `veil:http` for httpz workers, and `(unnamed)` for `std.Io.Threaded` pool threads.

On Windows the readings come from `NtQuerySystemInformation(SystemProcessInformation)` and `K32GetPerformanceInfo`. Neither needs admin, and both cover protected processes such as `MsMpEng.exe`. On Linux they come from `/proc`. Other systems report nothing.

## What is logged

- One line at start, then one per window (`NL_VITALS_LOG_S`, default 60 s) with that window's deltas.
- A warn line as soon as a sample crosses a spike threshold against the one before it: Defender read 256 MiB or more, own commit grew 128 MiB or more, own threads grew by 16 or more, free RAM under 1 GiB, or system commit at 95% of its limit. Each spike kind warns at most once per window.

In app mode these lines land in `veil-desk.log`, tagged `srv(vitals)`. Before this release the server's log lines were lost in app mode, because a GUI process's stderr is attached to nothing.

## Key Exports

- `sample(gpa) ?Sample`, `threadNames(gpa, *Names)`, `spikes(prev, cur) Spike`, `formatLine(...)`
- `Ctx` and `loop(*Ctx)`: the thread body, started from `main.zig`
- `renderJson(*Ctx, gpa)`: the route's body, the last 120 samples plus a fresh thread-name count
- `enabled(NL_VITALS)` (off with `0`, `off` or `false`) and `logEvery(NL_VITALS_LOG_S)` (5 to 3600 s)

## Rules it keeps

`loop` runs on a plain thread, so it never touches the Io runtime. It sleeps with kernel32 `Sleep` or `nanosleep`, never `io.sleep`, and its ring lock is a spinlock. A plain thread parked on `Io.Threaded`'s alert can wedge for good (see the desk's nap).
