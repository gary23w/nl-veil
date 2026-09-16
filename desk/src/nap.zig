//! nap.zig — a sleep, a clock and the worker heartbeats for the desk's own threads, none of which touch the Io
//! runtime's thread-parking primitive.
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
//! why the server loops that sleep through it never wedged. So EVERY sleep on a desk thread goes through here:
//! the poller's and the chat thread's ticks, netcli's retry backoff, the chat thread's classify poll and
//! tool-result retry, the watchdog's sampling and the hidden window's frame nap. io.sleep is left to test blocks
//! and to httpc's race timer, which runs as a task on the runtime's own pool (a DNS-named host only).
//!
//! A parked thread cannot report itself, so each worker loop also stamps a heartbeat the UI reads (the section
//! below): a worker that goes quiet says so on screen instead of leaving its last status up.
const std = @import("std");
const builtin = @import("builtin");

/// Sleep for `n` milliseconds without parking on the runtime's thread alert.
pub fn ms(n: u64) void {
    if (builtin.os.tag == .windows) {
        // negative = a relative interval, in 100 ns units
        const interval: std.os.windows.LARGE_INTEGER = -@as(i64, @intCast(n * 10_000));
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
    } else {
        // libc nanosleep, the shape src/worker/browser/util.zig uses: it ports across linux and macOS, where the
        // raw linux binding wants a different timespec than posix.timespec (which IS c.timespec)
        const ts: std.posix.timespec = .{ .sec = @intCast(n / 1000), .nsec = @intCast((n % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&ts, null);
    }
}

/// Milliseconds of Windows' unbiased interrupt time (QueryUnbiasedInterruptTime: counted from boot at the system
/// tick's resolution, and stopped while the machine sleeps). Only differences between readings mean anything, and
/// this clock keeps them honest: with wall-clock time a machine waking from an hour's sleep, or a clock stepped
/// forward, aged every heartbeat by the gap, and a live worker could read as silent until its next tick.
/// Elsewhere this returns 0, which the heartbeat readers treat as "not measured": the silent-worker line is a
/// Windows diagnosis for a Windows hang.
pub fn nowMs() i64 {
    if (builtin.os.tag == .windows) {
        var t: u64 = 0;
        _ = kernel32.QueryUnbiasedInterruptTime(&t);
        return @intCast(t / 10_000);
    }
    return 0;
}

const kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn QueryUnbiasedInterruptTime(unbiased_time: *u64) callconv(.winapi) i32;
} else struct {};

test "ms sleeps for about the time asked and never hangs; nowMs is monotonic where it is measured" {
    const t0 = nowMs();
    ms(15);
    const t1 = nowMs();
    if (builtin.os.tag == .windows) {
        try std.testing.expect(t1 - t0 >= 10); // the tick can round a 15 ms sleep down slightly
        try std.testing.expect(t1 - t0 < 2_000);
    } else {
        try std.testing.expectEqual(@as(i64, 0), t1);
    }
    ms(0);
}

// ------------------------------------------------------------------------------------------------ heartbeats
//
// Each worker loop owns one atomic in the Store (chat_beat_ms, poll_beat_ms) holding the nowMs reading up to
// which that thread is accounted for. The loop stamps "alive now" every tick; before a call that may block
// longer than SILENT_MS for a legitimate reason - a request with a timeout ceiling against a slow server - the
// thread stamps "accounted for until the ceiling" instead. The UI's silentMs therefore stays quiet through a slow
// but bounded call and speaks only once a thread has overrun everything it declared, which is what stuck means.
// Without the declared bounds the poller would read as stuck on every server poll that ran into its 6 s ceiling.

/// A worker loop has gone silent for longer than this and the UI should say so instead of showing its last
/// status. Windows calls a window unresponsive at ~5 s; the same yardstick fits a worker thread.
pub const SILENT_MS: i64 = 6_000;

/// The heartbeat THIS thread stamps, bound by `adopt`. Null on every other thread (the UI, the watchdog, test
/// blocks), where `beat` and `expect` do nothing - so code several threads share, like netcli's requests, can
/// declare its waits without knowing which thread it is running on.
threadlocal var beat_slot: ?*std.atomic.Value(i64) = null;

/// Bind this thread to its heartbeat atomic; null unbinds. A worker adopts right before its loop, so the one-time
/// startup work ahead of the loop stays unmeasured (the heartbeat reads 0, "not started") as it always has.
pub fn adopt(slot: ?*std.atomic.Value(i64)) void {
    beat_slot = slot;
}

/// "Alive now." The loop stamps this every tick, and a caller that declared a bound (`expect`) stamps it again
/// when the call returns.
pub fn beat() void {
    const slot = beat_slot orelse return;
    slot.store(nowMs(), .monotonic);
}

/// "Accounted for until `n` ms from now." Stamp this right before a call that may legitimately block that long,
/// then `beat` when it returns. Bounds do not nest: that beat ends whatever was declared before it.
pub fn expect(n: u64) void {
    const slot = beat_slot orelse return;
    const now = nowMs();
    const bound: i64 = @intCast(@min(n, std.math.maxInt(u32)));
    slot.store(if (now == 0) 0 else now +| bound, .monotonic); // 0 stays "not measured" off Windows
}

/// How long a worker has been silent at `now_ms`, given its heartbeat `beat_ms`, or null when there is nothing to
/// report: the worker ticked recently, is inside a bound it declared, has not started (0), or is not measured
/// (0 off Windows).
pub fn silentMs(now_ms: i64, beat_ms: i64) ?i64 {
    if (now_ms <= 0 or beat_ms <= 0) return null;
    const silent = now_ms -| beat_ms;
    return if (silent > SILENT_MS) silent else null;
}

test "silentMs: quiet while live or inside a declared bound, reports past SILENT_MS, ignores unmeasured beats" {
    const t0: i64 = 5 * 86_400_000; // five days of uptime, on nowMs's scale
    try std.testing.expect(silentMs(t0 + 100, t0) == null); // ticked 100 ms ago
    try std.testing.expect(silentMs(t0 + SILENT_MS, t0) == null); // AT the line is not past it
    try std.testing.expectEqual(@as(?i64, SILENT_MS + 1), silentMs(t0 + SILENT_MS + 1, t0));
    try std.testing.expect(silentMs(t0, t0 + 45_000) == null); // inside a declared 45 s ceiling
    try std.testing.expect(silentMs(t0 + 45_000 + SILENT_MS, t0 + 45_000) == null); // run out, not yet overrun
    try std.testing.expectEqual(@as(?i64, 7_000), silentMs(t0 + 52_000, t0 + 45_000)); // overran it by 7 s
    try std.testing.expect(silentMs(t0, 0) == null); // not started
    try std.testing.expect(silentMs(0, 0) == null); // not measured (off Windows)
    try std.testing.expect(silentMs(0, t0) == null);
}

test "adopt, beat and expect stamp only an adopted thread's heartbeat, and a declared bound holds silence off" {
    var hb = std.atomic.Value(i64).init(0);
    beat(); // nothing adopted on this thread: a no-op
    expect(60_000);
    try std.testing.expectEqual(@as(i64, 0), hb.load(.monotonic));

    adopt(&hb);
    defer adopt(null); // test blocks share this thread: leave no binding behind for the next one
    beat();
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(i64, 0), hb.load(.monotonic)); // not measured, so never reported
        expect(60_000);
        try std.testing.expectEqual(@as(i64, 0), hb.load(.monotonic));
        return;
    }
    const now = nowMs();
    try std.testing.expect(now - hb.load(.monotonic) < 2_000);
    expect(60_000);
    const held = hb.load(.monotonic);
    try std.testing.expect(held - now >= 59_000 and held - now < 62_000);
    try std.testing.expect(silentMs(now + 60_000, held) == null); // a slow call still inside its ceiling
    try std.testing.expect(silentMs(now + 60_000 + SILENT_MS + 2_000, held) != null); // one that overran it
    beat(); // the call returned: its bound ends
    try std.testing.expect(nowMs() - hb.load(.monotonic) < 2_000);
}
