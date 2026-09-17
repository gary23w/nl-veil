# nap

**File:** `desk/src/nap.zig`  
**Module:** `desk`  
**Description:** The desk threads' millisecond sleep and wall clock, neither of which parks on the Io runtime's per-thread alert, plus the worker heartbeats behind the "silent for Ns" notices.

---

## Purpose Summary

On Windows, `std.Io.Threaded` implements `sleep` by parking the thread on `NtWaitForAlertByThreadId`, the same per-thread alert the runtime uses to wake mutex waiters, condition waiters and task awaiters. The desk's poller, chat and watchdog threads are plain `std.Thread`s, not the runtime's own: they get no cancelation bookkeeping, and an alert they did not expect is declared unreachable, which is undefined behaviour in a release build. Thread alerts are sticky and shared by everything on the thread, so one stray alert (the runtime's own request-versus-timer race can leave one behind) lands in the next sleep. On 2026-09-02 that left the poller and chat threads parked with no timeout in effect, hours into a session: the chat pane froze mid-turn with "working." on the status line while the server's threads in the same process kept running. A non-alertable `NtDelayExecution` ignores thread alerts entirely, and the header credits it for the server loops never wedging, so every sleep on a desk thread goes through this file. `io.sleep` is left to test blocks and to httpc's race timer, which runs as a task on the runtime's own pool and only for a host given as a DNS name.

A thread parked like that cannot report itself, so the file also carries the heartbeats: each worker loop stamps an atomic the UI reads, and a worker that goes quiet is named on screen instead of leaving its last status up.

## Key Exports

- `ms(n)` — sleep `n` milliseconds: `NtDelayExecution` on Windows, libc `nanosleep` elsewhere
- `nowMs()` — milliseconds of unbiased interrupt time on Windows (`QueryUnbiasedInterruptTime`: from boot, stopped while the machine sleeps); 0 elsewhere, which heartbeat readers treat as "not measured"
- `SILENT_MS` (6000) — how far past its heartbeat a worker may be before the UI says so instead of showing its last status; the yardstick is Windows calling a window unresponsive at ~5 s
- `adopt(slot)` — bind the calling thread to its heartbeat atomic; null unbinds
- `beat()` — stamp "alive now" into the calling thread's heartbeat
- `expect(n)` — stamp "accounted for until `n` ms from now", right before a call that may legitimately block that long
- `silentMs(now_ms, beat_ms)` — the silence to report, or null when the worker ticked recently, is inside a bound it declared, has not started (0), or is not measured (0)

## Dependencies

- `std`, `builtin` — no desk modules
- Windows: `std.os.windows.ntdll.NtDelayExecution`, and kernel32's `QueryUnbiasedInterruptTime` declared locally
- POSIX: `std.c.nanosleep` with a `std.posix.timespec`

## Usage Context

The sleeps. `poller.zig`'s `Poller.run` naps in up to ten 100 ms slices between refreshes, leaving early for a pending command. `chat.zig`'s `Chat.run` naps 100 ms per idle tick, and while a turn streams it naps 33 ms twice (pumping the stream after each) and then 34 ms, keeping the 100 ms tick cadence; its `syncGatewayClassify` polls a stream every 12 ms for up to 10 s, and `postToolResult` waits 250 ms between its four attempts. `netcli.zig`'s `httpReq` backs off 120 ms and then 240 ms between retries. `watchdog.zig`'s sampler naps `SAMPLE_MS` (250 ms), and `main.zig`'s render loop naps `HIDDEN_SLEEP_MS` (200 ms) per frame while the window is hidden to the tray or minimized.

The heartbeats. `Chat.run` and `Poller.run` each `adopt` their Store atomic (`chat_beat_ms`, `poll_beat_ms`) right before their loop, `beat` at the top of every pass and after every nap slice, and unbind when the loop exits. `netcli.httpReq` declares `timeout_s` with `expect` before each attempt and beats on the way out; `chat.zig` does the same around its two direct Ollama probes (`/api/tags` with 5 s, `/api/ps` with 4 s), and `syncGatewayClassify` beats on every poll. `main.zig` reads both: `drawChat` replaces the chat status line with "chat thread silent for Ns - restart the desk", and `drawTitlebar` replaces the server chip with "poller thread silent for Ns - restart the desk" in orange, hiding the Cloudflare mark, which the poller also keeps current. Both lines are formatted by `silentNotice`, whose comptime check proves each fits its 96-byte buffer with the widest number an i64 prints.

## Notable Implementation Details

- Windows `ms` passes `NtDelayExecution` a non-alertable (`.FALSE`) negative interval of `n * 10_000`; negative means relative time, in 100 ns units. The returned status is discarded.
- The POSIX branch splits `n` into whole seconds and a nanosecond remainder below 1e9 and ignores the return value, so an interrupted `nanosleep` returns early rather than resuming. It copies the shape `src/worker/browser/util.zig` uses: `std.Thread.sleep` does not exist in this Zig (an earlier cut called it and broke the Linux CI build, which the Windows build never analysed), and the raw linux binding wants a different timespec than `posix.timespec`.
- `nowMs` divides the 100 ns unbiased interrupt time by 10 000, so it counts from boot at the system tick's resolution (about 15.6 ms by default), and only the difference between two readings is meaningful. Unbiased means time asleep is left out, and no wall-clock change moves it. Until 2026-09-16 it read wall-clock time (`RtlGetSystemTimePrecise`), under which a machine waking from an hour's sleep, or a clock stepped forward, aged every heartbeat by the gap, so a live worker could read as silent until its next tick.
- The heartbeat slot is `threadlocal`, so shared code can declare its waits without knowing its thread: on the UI thread, the watchdog or a test block nothing is adopted, and `beat` and `expect` do nothing. Adopting at the loop rather than at thread start keeps each worker's one-time startup work unmeasured (the heartbeat reads 0), as it was before.
- Why bounds are declared: the poller's fleet GET has a 6 s ceiling and a refresh makes several server calls, so a heartbeat stamped only per tick would call the poller stuck on every poll a slow server let run to its timeout. `expect` moves the stamp to the end of the ceiling, and silence counts only once it has passed that by `SILENT_MS`. Bounds do not nest: the `beat` after a call ends whatever was declared before it. `expect` clamps `n` to `u32` milliseconds and stores 0 off Windows.
- Only calls that declare a bound are covered. A synchronous child process on the chat thread (the `sync-manifest` and `sync-read` verbs, git, a neuron recall) has no ceiling to declare, so one that runs past `SILENT_MS` shows the chat notice until it returns.
- Off Windows every stamp is 0, so `silentMs` never reports there: the silent-worker notices are a Windows diagnosis for a Windows hang.
- The notices' first version (v1.1.0) never rendered: "chat thread silent for {d}s - the desk's worker is stuck; restart the desk (the server is unaffected)" is 98 bytes before the digits, so `bufPrint` into the 96-byte status buffer failed on every frame and only its "chat thread silent" fallback showed. The poller's heartbeat was written and read nowhere.
- Tests, registered in `desk/src/tests.zig` (until 2026-09-16 they were not, and never ran): `ms(15)` takes at least 10 ms and under 2 s on Windows, `nowMs` is 0 elsewhere, and `ms(0)` returns; the pure `silentMs` rules (exactly `SILENT_MS` is not yet silent, a declared bound holds the silence off until it runs out, 0 is never reported); and `adopt`, `beat` and `expect` on the test thread — no-ops while unbound, a 60 s bound stamped about 60 s ahead, silence reported only past it, and the binding released for the tests that follow. `main.zig` has a test that renders both notices in their real buffers, the widest silence included.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
