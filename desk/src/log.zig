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

// ---- tests ---------------------------------------------------------------------------------------------
//
// The ring is process-global and every other desk module logs while ITS tests run, so a test here can never
// assume an empty ring — each one drains what is pending first and then asserts only about the lines it
// wrote itself. Same reason the trace flag and the clock are captured and restored: these tests share one
// logger with the rest of the suite.

/// Consume everything currently pending so the next `drain` returns only what the test emits.
fn testDrainPending() void {
    var buf: [64]Line = undefined;
    while (drain(&buf) > 0) {}
}

test "drain hands the flusher every line written since its last drain, oldest-first, then nothing" {
    testDrainPending();
    info("alpha {d}", .{1});
    warn("bravo {s}", .{"x"});
    err("charlie", .{});
    var out: [8]Line = undefined;
    try std.testing.expectEqual(@as(usize, 3), drain(&out));
    try std.testing.expectEqualStrings("alpha 1", out[0].str());
    try std.testing.expectEqualStrings("bravo x", out[1].str());
    try std.testing.expectEqualStrings("charlie", out[2].str());
    try std.testing.expectEqual(Level.info, out[0].level);
    try std.testing.expectEqual(Level.warn, out[1].level);
    try std.testing.expectEqual(Level.err, out[2].level);
    // consuming: the flusher appends what it drains to <data>/veil-desk.log, so a second read of the same
    // line is a duplicated log entry, not a harmless re-read.
    try std.testing.expectEqual(@as(usize, 0), drain(&out));
}

test "a drain that cannot take everything loses nothing — the cursor resumes at the first line it left" {
    testDrainPending();
    for (0..5) |i| info("line {d}", .{i});
    var two: [2]Line = undefined;
    try std.testing.expectEqual(@as(usize, 2), drain(&two));
    try std.testing.expectEqualStrings("line 0", two[0].str());
    try std.testing.expectEqualStrings("line 1", two[1].str());
    var rest: [8]Line = undefined;
    try std.testing.expectEqual(@as(usize, 3), drain(&rest));
    try std.testing.expectEqualStrings("line 2", rest[0].str());
    try std.testing.expectEqualStrings("line 3", rest[1].str());
    try std.testing.expectEqualStrings("line 4", rest[2].str());
}

test "the ring holds the newest CAP lines; a flusher that fell behind skips the lost oldest" {
    testDrainPending();
    const over = 7; // written past the ring's capacity, so the oldest `over` lines are overwritten in place
    for (0..CAP + over) |i| info("l{d}", .{i});
    const out = try std.testing.allocator.alloc(Line, CAP);
    defer std.testing.allocator.free(out);
    // not CAP+over (the ring cannot hold them) and not 0 (the cursor must not be left behind the window)
    try std.testing.expectEqual(@as(usize, CAP), drain(out));
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&a, "l{d}", .{over}), out[0].str());
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&b, "l{d}", .{CAP + over - 1}), out[CAP - 1].str());
    try std.testing.expectEqual(@as(usize, 0), drain(out));
}

test "snapshot is non-consuming: the overlay repaints without stealing the flusher's lines" {
    testDrainPending();
    for (0..6) |i| info("s{d}", .{i});
    var win: [3]Line = undefined;
    try std.testing.expectEqual(@as(usize, 3), snapshot(&win));
    try std.testing.expectEqualStrings("s3", win[0].str()); // the NEWEST three, oldest-first
    try std.testing.expectEqualStrings("s4", win[1].str());
    try std.testing.expectEqualStrings("s5", win[2].str());
    var again: [3]Line = undefined;
    try std.testing.expectEqual(@as(usize, 3), snapshot(&again));
    try std.testing.expectEqualStrings("s3", again[0].str()); // F12 redraws every frame; nothing consumed
    var all: [16]Line = undefined;
    try std.testing.expectEqual(@as(usize, 6), drain(&all)); // …and the file still gets all six
    try std.testing.expectEqualStrings("s0", all[0].str());
}

test "an overlay that asks for more than the ring holds gets CAP lines, not a walk off the end" {
    testDrainPending();
    for (0..CAP + 3) |i| info("o{d}", .{i});
    const out = try std.testing.allocator.alloc(Line, CAP + 64);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, CAP), snapshot(out));
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&a, "o{d}", .{3}), out[0].str());
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&b, "o{d}", .{CAP + 2}), out[CAP - 1].str());
    testDrainPending(); // leave the ring clean for whatever runs next
}

test "a line longer than the ring's line buffer is truncated to it, and its neighbour is unharmed" {
    testDrainPending();
    const width = (Line{}).buf.len; // the module's real line width, read off the struct
    info("{s}", .{"x" ** (width + 180)});
    info("after", .{});
    var out: [4]Line = undefined;
    try std.testing.expectEqual(@as(usize, 2), drain(&out));
    // the overflowing line keeps the prefix that fit and stops at the buffer — it cannot run into the next
    // slot, which is the whole reason Line carries its own fixed buffer instead of a slice.
    try std.testing.expectEqual(width, out[0].str().len);
    for (out[0].str()) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
    try std.testing.expectEqualStrings("after", out[1].str());
}

test "silencing the trace firehose never silences an error" {
    const was = traceEnabled();
    defer setTraceEnabled(was);
    // trace/dbg default OFF because default-on tracing kept the flusher writing to the OneDrive-synced data
    // dir every second. That fix must never have cost the log its errors.
    setTraceEnabled(false);
    testDrainPending();
    trace("fn entry", .{});
    dbg("per-request chatter", .{});
    err("the thing failed", .{});
    info("still informing", .{});
    warn("still warning", .{});
    var out: [8]Line = undefined;
    try std.testing.expectEqual(@as(usize, 3), drain(&out));
    try std.testing.expectEqualStrings("the thing failed", out[0].str());
    try std.testing.expectEqualStrings("still informing", out[1].str());
    try std.testing.expectEqualStrings("still warning", out[2].str());
    // flipped on for a diagnosis session, both come back — as .dbg, so the overlay can tell them apart
    setTraceEnabled(true);
    trace("fn entry", .{});
    dbg("per-request chatter", .{});
    try std.testing.expectEqual(@as(usize, 2), drain(&out));
    try std.testing.expectEqual(Level.dbg, out[0].level);
    try std.testing.expectEqual(Level.dbg, out[1].level);
    setTraceEnabled(false);
    testDrainPending();
}

test "every level tag is the same width, so the log file and the F12 overlay stay column-aligned" {
    const width = levelTag(.info).len;
    for (std.enums.values(Level)) |l| {
        try std.testing.expectEqual(width, levelTag(l).len);
        for (std.enums.values(Level)) |other| { // and distinct: the tag is how a reader spots an error
            if (l == other) continue;
            try std.testing.expect(!std.mem.eql(u8, levelTag(l), levelTag(other)));
        }
    }
    try std.testing.expectEqualStrings("ERR ", levelTag(.err)); // padded, not "ERR"
}

test "setClock stamps the lines written after it — a line never reads the clock itself" {
    const was = @atomicLoad(i64, &g_clock, .monotonic);
    defer setClock(was);
    testDrainPending();
    // Safe to synthesise: emit() copies whatever the poller last stamped and never calls a clock, so these
    // stamps cannot race a real second boundary.
    setClock(1_784_000_000);
    info("stamped", .{});
    setClock(1_784_000_042);
    info("restamped", .{});
    var out: [4]Line = undefined;
    try std.testing.expectEqual(@as(usize, 2), drain(&out));
    try std.testing.expectEqual(@as(i64, 1_784_000_000), out[0].t_s);
    try std.testing.expectEqual(@as(i64, 1_784_000_042), out[1].t_s);
}
