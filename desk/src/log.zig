//! log.zig — a tiny thread-safe ring log for veil-desk. Both threads write (the UI thread via the F12
//! overlay's producers, the poller thread via deploy/delete/tray/http). Two readers: `drain` (consuming,
//! for the poller to flush new lines to <data>/veil-desk.log) and `snapshot` (non-consuming, for the F12
//! in-app overlay). Fixed-capacity, allocation-free on the hot path — a debug facility, not a firehose.

const std = @import("std");

pub const Level = enum { info, warn, dbg, err };

pub fn levelTag(l: Level) []const u8 {
    return switch (l) {
        .info => "INFO",
        .warn => "WARN",
        .dbg => "DBG ",
        .err => "ERR ",
    };
}

pub const Line = struct {
    t_s: i64 = 0,
    level: Level = .info,
    buf: [220]u8 = [_]u8{0} ** 220,
    len: u16 = 0,
    pub fn str(l: *const Line) []const u8 {
        return l.buf[0..l.len];
    }
};

// Sized for whole-app function-entry tracing (see `trace`), which is FAR heavier volume than an
// info/warn/err-only log: a small ring would evict real signal (errors, tool calls, cast lifecycle) behind a
// firehose of trace lines within seconds. 8192 lines * 220B = ~1.8MB, fine for a desktop app's static data.
const CAP = 8192;

var g_lines: [CAP]Line = undefined;
var g_write: usize = 0; // monotonic next-write index
var g_drain: usize = 0; // next index the file-flusher hasn't consumed
var g_clock: i64 = 0;
var g_held = std.atomic.Value(bool).init(false);

/// Function-entry tracing toggle (see `trace`). Defaults OFF: default-on tracing put ≥1 line in the ring
/// EVERY second forever (poller tick + netcli lines), which kept the log flusher writing to the
/// (OneDrive-synced) data dir every second — measurable idle CPU in the desk, OneDrive, AND Defender.
/// Flip on for a diagnosis session via the SIM hook ("trace on") or log.setTraceEnabled(true). Atomic:
/// the poller thread and UI thread both call `trace`.
var g_trace_on = std.atomic.Value(bool).init(false);

pub fn setTraceEnabled(on: bool) void {
    g_trace_on.store(on, .monotonic);
}

pub fn traceEnabled() bool {
    return g_trace_on.load(.monotonic);
}

fn lock() void {
    while (g_held.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn unlock() void {
    g_held.store(false, .release);
}

/// The poller stamps the current wall-clock (seconds) each refresh so log lines get a real time.
pub fn setClock(t_s: i64) void {
    @atomicStore(i64, &g_clock, t_s, .monotonic);
}

fn emit(level: Level, comptime fmt: []const u8, args: anytype) void {
    var ln: Line = .{ .t_s = @atomicLoad(i64, &g_clock, .monotonic), .level = level };
    const s = std.fmt.bufPrint(&ln.buf, fmt, args) catch blk: {
        // formatting overflowed the line buffer — keep the prefix that fit.
        break :blk ln.buf[0..ln.buf.len];
    };
    ln.len = @intCast(s.len);
    lock();
    defer unlock();
    g_lines[g_write % CAP] = ln;
    g_write += 1;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit(.info, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(.warn, fmt, args);
}
/// Diagnostic chatter (per-request http lines etc.) — gated with `trace`: ungated, these landed a line in
/// the ring every few seconds forever, which kept the log flusher writing to the (OneDrive-synced) data
/// dir around the clock — the surviving half of the idle-churn problem after trace itself went quiet.
pub fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (!g_trace_on.load(.monotonic)) return;
    emit(.dbg, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(.err, fmt, args);
}

/// Function-entry tracing: one call at the top of (almost) every non-hot-path function in the desktop app,
/// so a live run's veil-desk.log reads as a call trace (which function ran, in what order, with what key
/// arguments). Deliberately excluded from main.zig's per-frame draw/render functions (60fps would flood the
/// ring and defeat the purpose). Gated by `g_trace_on` (default on) so it can be silenced without a rebuild.
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (!g_trace_on.load(.monotonic)) return;
    emit(.dbg, fmt, args);
}

/// Consuming read for the file flusher: copies the lines written since the last drain into `out`
/// (oldest-first), advances the drain cursor by what it copied, returns the count.
pub fn drain(out: []Line) usize {
    lock();
    defer unlock();
    var start = g_drain;
    if (g_write - start > CAP) start = g_write - CAP; // fell behind → skip the lost oldest
    var n: usize = 0;
    var i = start;
    while (i < g_write and n < out.len) : (i += 1) {
        out[n] = g_lines[i % CAP];
        n += 1;
    }
    g_drain = i;
    return n;
}

/// Non-consuming read for the overlay: the most recent min(out.len, CAP) lines, oldest-first.
pub fn snapshot(out: []Line) usize {
    lock();
    defer unlock();
    var start: usize = 0;
    if (g_write > out.len) start = g_write - out.len;
    if (g_write > CAP and start < g_write - CAP) start = g_write - CAP;
    var n: usize = 0;
    var i = start;
    while (i < g_write and n < out.len) : (i += 1) {
        out[n] = g_lines[i % CAP];
        n += 1;
    }
    return n;
}
