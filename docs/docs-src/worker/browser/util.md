# util

**File:** `src/worker/browser/util.zig`  
**Module:** `worker/browser`  
**Description:** Small shared helpers for the browser layer.

---

## Purpose Summary

Currently one helper: a millisecond sleep that is safe on any thread. It exists because `std.Io.sleep` throws on a thread that is not an Io-managed task — e.g. an httpz request-worker thread (the `/api/v1/chat/tool` path) or the broker's accept thread — and swallowing that error turned every browser wait loop into a busy-spin that never actually waited, so a session or daemon never had time to come up.

## Key Exports

- `sleepMs(ms: u64)` — raw-thread-safe millisecond sleep using the OS primitive directly, so it behaves identically on any thread.

## Dependencies

- `std` / `builtin` only; on Windows it declares and calls kernel32 `Sleep` directly.

## Usage Context

The browser layer's wait/poll loops all lean on it: `launch.readEndpoint` (port-file poll), `session.waitReady` (readiness poll), and `host.zig`'s daemon watch loop and client-side spawn wait.

## Notable Implementation Details

- Windows: kernel32 `Sleep`, with the ms clamped to u32.
- POSIX: `std.Thread.sleep` does not exist in this Zig (0.16), so it is a timespec + libc `nanosleep` — `std.c`, *not* `std.os.linux`, because on a macOS target the linux binding wants `os.linux.timespec` while `posix.timespec` is `c.timespec`, so the linux call fails to compile there; libc's `nanosleep` ports across linux + macOS. The ms are split into whole seconds + remainder so `nsec` stays under 1e9.

---

*Case file grounded in the module's `//!` header and public API.*
