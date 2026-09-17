# util

**File:** `src/worker/browser/util.zig`  
**Module:** `worker/browser`  
**Description:** Small shared helpers for the browser layer.

---

## Purpose Summary

Currently one helper: a millisecond sleep that is safe on any thread and that no thread alert can end. The browser layer's wait loops use it, and so does the rest of the tree wherever it sleeps on a thread the Io runtime did not spawn. It is not `std.Io.sleep` because on Windows that parks the thread on the runtime's per-thread alert (`NtWaitForAlertByThreadId`), and on a thread the runtime did not spawn — an httpz request-worker thread (the `/api/v1/chat/tool` path), the broker's accept thread, a chat turn — a wake the runtime did not ask for is `unreachable`. Measured on Zig 0.16.0 (2026-09-16): with an alert pending, `io.sleep` panicked in a Debug build and returned at once in ReleaseFast, while kernel32 `Sleep` slept its full time and left the alert pending. Alerts are sticky, so one stray alert lands in the next park (`desk/src/nap.zig` has the 2026-09-02 desk freeze it caused). `io.sleep` does not throw on such a thread in this std, and with no alert it waits its full time.

## Key Exports

- `sleepMs(ms: u64)` — raw-thread-safe millisecond sleep using the OS primitive directly, so it behaves identically on any thread.

## Dependencies

- `std` / `builtin` only; on Windows it declares and calls kernel32 `Sleep` directly.

## Usage Context

The browser layer's wait/poll loops all lean on it: `launch.readEndpoint` (port-file poll), `session.waitReady` (readiness poll), and `host.zig`'s daemon watch loop and client-side spawn wait.

Outside the browser layer it is the sleep for threads the Io runtime did not spawn: `llm.zig` (the stream tail loop's 20 ms poll and `retryWait`'s slices, on the chat turn's thread), `rate.zig` (`acquire`'s waits), `llamaeng.zig` (the idle unloader), `config/cf_tunnel.zig` (the tunnel's threads), `config/cf_oauth.zig` (the wait for another thread's token refresh), `cli.zig` (the CLI's main thread) and `run.zig` (the worker's round loop).

## Notable Implementation Details

- Windows: kernel32 `Sleep`, with the ms clamped to u32. It is a non-alertable `NtDelayExecution`, so a thread alert neither ends it nor is consumed by it. A Windows-only test pins that: a raw thread alerts itself, sleeps 150 ms, then drains the alert with a zero-timeout `NtWaitForAlertByThreadId` (`STATUS_ALERTED` is the positive control that the alert was pending the whole time).
- POSIX: `std.Thread.sleep` does not exist in this Zig (0.16), so it is a timespec + libc `nanosleep` — `std.c`, *not* `std.os.linux`, because on a macOS target the linux binding wants `os.linux.timespec` while `posix.timespec` is `c.timespec`, so the linux call fails to compile there; libc's `nanosleep` ports across linux + macOS. The ms are split into whole seconds + remainder so `nsec` stays under 1e9.

---

*Case file grounded in the module's `//!` header and public API.*
