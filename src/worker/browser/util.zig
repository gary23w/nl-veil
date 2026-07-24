//! Small shared helpers for the browser layer.

const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Raw-thread-safe millisecond sleep. std.Io.sleep THROWS on a thread that is not an Io-managed task — e.g. an
/// httpz request-worker thread (the /api/v1/chat/tool path) or the broker's accept thread — and swallowing that
/// error turned every browser wait loop into a busy-spin that never actually waited (so a session/daemon never
/// had time to come up). This uses the OS sleep directly, so it behaves identically on any thread.
pub fn sleepMs(ms: u64) void {
    if (builtin.os.tag == .windows) {
        Sleep(@intCast(@min(ms, @as(u64, std.math.maxInt(u32)))));
    } else {
        // std.Thread.sleep does not exist in this Zig (0.16) — the tree's raw-thread POSIX sleep is a
        // timespec + libc nanosleep (see tools.zig watch / run.zig / mcp/client.zig). Split ms into whole
        // seconds + remainder so nsec stays under 1e9. std.c, NOT std.os.linux: for a macOS target the
        // linux binding wants os.linux.timespec while posix.timespec IS c.timespec, so the linux call
        // fails to compile there — libc's nanosleep is the one that ports across linux + macOS.
        const ts = std.posix.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

// ---------------------------------------------------------------------------
// tests — sleepMs is a WAIT, on any thread
//
// The bug this helper exists for is silent: a sleep that returns immediately looks exactly like a sleep that
// worked, and only shows up much later as a browser wait loop that busy-spun through its whole budget without
// giving the daemon time to come up. So every test here is a CLOCK assertion — time actually passed — never
// just "it returned". Each has a floor (a no-op sleep fails it) and a ceiling (a blown unit conversion fails
// it); the gap between them is wide on purpose, because a loaded CI box can stretch any sleep but cannot
// shrink one.
// ---------------------------------------------------------------------------

/// Monotonic milliseconds. `std.time` in Zig 0.16 carries only unit constants — the clock itself lives behind
/// `Io` — so the tests take an io purely to read the clock. Nothing under test touches Io; that is the point.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

test "sleepMs actually waits: 60ms neither returns instantly nor stretches into seconds" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const t0 = nowMs(io);
    sleepMs(60);
    const el = nowMs(io) - t0;

    // Floor well under 60: Windows' Sleep is quantized to the system tick (~15.6ms by default) and may return
    // a tick early. A busy-spin or a swallowed error lands at ~0 and fails this regardless.
    try std.testing.expect(el >= 30);
    // Ceiling: pins the unit. Reading the argument as seconds (or letting ns overflow into a longer wait)
    // shows up here as ~60s; ordinary scheduler noise does not come close.
    try std.testing.expect(el < 5000);
}

test "sleepMs(0): the zero boundary yields, it does not hang" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const t0 = nowMs(io);
    sleepMs(0);
    const el = nowMs(io) - t0;
    // 0 goes to Sleep(0)/nanosleep(0,0) — a scheduler yield, which callers use as a cheap "let another thread
    // run". The bound is deliberately loose (a tick of quantization is fine); what it rules out is 0 falling
    // through into a block — an unsigned underflow to a huge duration, or a wait on a deadline in the past.
    try std.testing.expect(el < 1000);
}

test "sleepMs waits on a RAW thread — the whole reason this helper exists" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // std.Io.sleep THROWS on a thread that is not an Io-managed task (an httpz request worker, the broker's
    // accept thread). This is that thread: spawned raw, with no io in scope, exactly like the callers in
    // host.zig / launch.zig / session.zig. Timed from the parent so the raw thread stays raw.
    const t0 = nowMs(io);
    const th = try std.Thread.spawn(.{}, struct {
        fn go() void {
            sleepMs(60);
        }
    }.go, .{});
    th.join();
    const el = nowMs(io) - t0;

    try std.testing.expect(el >= 30); // spawn+join overhead only ever inflates this
    try std.testing.expect(el < 5000);
}

test "sleepMs: sub-tick sleeps still wait, and repeated calls accumulate" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 10ms is under the default Windows tick, the size the browser layer's tightest poll loops use. Five in a
    // row must add up: a helper where only the first call waits, or where a sub-tick request degrades to a
    // no-op, passes the single-sleep test above and fails this one.
    const t0 = nowMs(io);
    for (0..5) |_| sleepMs(10);
    const el = nowMs(io) - t0;

    try std.testing.expect(el >= 20);
    try std.testing.expect(el < 5000);
}

test "sleepMs: a duration past one second is split into whole seconds + remainder, not dropped" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The boundary the POSIX branch's sec/nsec split is written for. Putting the whole duration in `nsec`
    // would push it to 1.1e9 — past the 1e9 nanosleep accepts — and the call fails with EINVAL and returns
    // AT ONCE. The return value is discarded (`_ =`), so the only way that shows up is on the clock.
    const t0 = nowMs(io);
    sleepMs(1100);
    const el = nowMs(io) - t0;

    try std.testing.expect(el >= 600);
    try std.testing.expect(el < 10_000);
}
