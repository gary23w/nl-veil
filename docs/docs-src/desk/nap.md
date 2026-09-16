# nap

**File:** `desk/src/nap.zig`  
**Module:** `desk`  
**Description:** A millisecond sleep and a wall clock for the desk's own threads that never park on the Io runtime's per-thread alert, plus the threshold after which a silent worker loop is reported.

---

## Purpose Summary

On Windows, `std.Io.Threaded` implements `sleep` by parking the thread on `NtWaitForAlertByThreadId`, the same per-thread alert the runtime uses to wake mutex waiters, condition waiters and task awaiters. The desk's poller and chat loops run on plain `std.Thread`s, which are not the runtime's own threads: they get no cancelation bookkeeping, and an alert they did not expect is declared unreachable, which is undefined behaviour in a release build. Thread alerts are sticky and shared by everything on the thread, so one stray alert (the runtime's own request-versus-timer race can leave one behind) lands in the next sleep. On 2026-09-02 that left both threads parked with no timeout in effect, hours into a session: the chat pane froze mid-turn with "working." on the status line while the server's threads in the same process kept running. A non-alertable `NtDelayExecution` ignores thread alerts entirely, and the header credits it for the server loops never wedging, so the desk's loops sleep through it here.

## Key Exports

- `ms(n)` — sleep `n` milliseconds: `NtDelayExecution` on Windows, libc `nanosleep` elsewhere
- `nowMs()` — wall-clock milliseconds from `RtlGetSystemTimePrecise` on Windows; 0 elsewhere, which heartbeat readers treat as "not measured"
- `SILENT_MS` (6000) — how long a worker loop may go without a heartbeat before the UI should say so instead of showing its last status; the yardstick is Windows calling a window unresponsive at ~5 s

## Dependencies

- `std`, `builtin` — no desk modules
- Windows: `std.os.windows.ntdll.NtDelayExecution` and `RtlGetSystemTimePrecise`
- POSIX: `std.c.nanosleep` with a `std.posix.timespec`

## Usage Context

`poller.zig`'s `Poller.run` naps in up to ten 100 ms slices between refreshes, leaving early for a pending command, and stores `nap.nowMs()` into `store.poll_beat_ms` at the top of each pass and after each slice. `chat.zig`'s `Chat.run` naps 100 ms per idle tick; while a turn streams it naps 33 ms twice (pumping the stream after each) and then 34 ms, keeping the 100 ms tick cadence, and stores `store.chat_beat_ms` at each tick and after each 33 ms nap. `main.zig`'s render loop naps `HIDDEN_SLEEP_MS` (200 ms) per frame while the window is hidden to the tray or minimized, and its chat pane compares `nap.nowMs()` with `chat_beat_ms` and, past `SILENT_MS`, replaces the chat status line with a "chat thread silent" notice. `store.zig` declares both heartbeat atomics (0 = not started).

## Notable Implementation Details

- Windows `ms` passes `NtDelayExecution` a non-alertable (`.FALSE`) negative interval of `n * 10_000`; negative means relative time, in 100 ns units. The returned status is discarded.
- The POSIX branch splits `n` into whole seconds and a nanosecond remainder below 1e9 and ignores the return value, so an interrupted `nanosleep` returns early rather than resuming. It copies the shape `src/worker/browser/util.zig` uses: `std.Thread.sleep` does not exist in this Zig (an earlier cut called it and broke the Linux CI build, which the Windows build never analysed), and the raw linux binding wants a different timespec than `posix.timespec`.
- `nowMs` divides the 100 ns system-time count by 10 000 with no epoch shift, so it counts from 1601 rather than the Unix epoch, and it is adjustable system time rather than a monotonic counter. Only the difference between two `nowMs` readings is meaningful.
- Off Windows `nowMs` returns 0, so the chat pane's `now - beat` check never fires there: the silent-worker line is a Windows diagnosis for a Windows hang.
- Only the loops' tick sleeps come through this file. Other sleeps on desk threads still call `io.sleep`: `netcli.zig`'s retry backoff, `chat.zig`'s `postToolResult` retry and `syncGatewayClassify` poll loop, and the watchdog thread's sampling loop. `poll_beat_ms` is written but read nowhere, so only the chat thread's silence reaches the screen.
- The one test checks that `ms(15)` takes at least 10 ms (the tick can round a 15 ms sleep down) and under 2 s on Windows, that `nowMs` is 0 elsewhere, and that `ms(0)` returns. It was added so a cross-compile analyses both helpers, but `desk/src/tests.zig`, whose header says tests in unlisted files never run, does not list `nap.zig`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
