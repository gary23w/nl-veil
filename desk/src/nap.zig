//! nap.zig — a tick sleep and a clock for the desk's own threads that never touch the Io runtime's
//! thread-parking primitive.
//!
//! On Windows, std.Io.Threaded implements `sleep` by parking the thread on NtWaitForAlertByThreadId: the same
//! per-thread alert the runtime uses to wake its mutex waiters, condition waiters and task awaiters. On
//! 2026-09-02 the desk's poller and chat threads were found parked in that sleep with no timeout in effect,
//! hours into a session, while the server's threads in the same process kept running - the chat pane froze
//! mid-turn with the server healthy, and the status line kept saying "working.". A plain std.Thread is not one
//! of the runtime's own threads, so it gets no cancelation bookkeeping there, and an alert it did not expect
//! is declared unreachable - undefined behaviour in a release build. Thread alerts are sticky and shared by
//! everything on the thread, so one stray alert (the runtime's own request-versus-timer race can leave one
//! behind) lands in the next sleep. A non-alertable NtDelayExecution ignores thread alerts entirely, which is
//! why the server loops that sleep through it never wedged. So the desk's loops sleep here.
const std = @import("std");
const builtin = @import("builtin");

/// Sleep for `n` milliseconds without parking on the runtime's thread alert.
pub fn ms(n: u64) void {
    if (builtin.os.tag == .windows) {
        // negative = a relative interval, in 100 ns units
        const interval: std.os.windows.LARGE_INTEGER = -@as(i64, @intCast(n * 10_000));
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
    } else {
        std.Thread.sleep(n * std.time.ns_per_ms);
    }
}

/// Wall-clock milliseconds (Windows: RtlGetSystemTimePrecise; elsewhere the Io clock is used by the callers).
pub fn nowMs() i64 {
    if (builtin.os.tag == .windows) {
        return @intCast(@divTrunc(std.os.windows.ntdll.RtlGetSystemTimePrecise(), 10_000));
    }
    return 0;
}

/// A worker loop has gone silent for longer than this and the UI should say so instead of showing its last
/// status. Windows calls a window unresponsive at ~5 s; the same yardstick fits a worker thread.
pub const SILENT_MS: i64 = 6_000;
