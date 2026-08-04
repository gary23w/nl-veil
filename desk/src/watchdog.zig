//! watchdog.zig — turns an invisible UI freeze into a logged diagnosis.
//!
//! WHY THIS EXISTS. Twice in one day Windows logged
//!   Event 1002: "veil.exe stopped interacting with Windows and was closed"
//! for this app. That is not a crash: the render thread stopped pumping the Windows message queue, so the OS
//! marked the window Not Responding and closed it. The desk log's last line was 14 minutes before the close.
//!
//! A hang leaves NOTHING to read afterwards — no panic (the self-symbolicating handler never runs), no dump
//! (Windows only dumps faults, not hangs), no stack. Every post-mortem tool in the box is useless against it,
//! which is exactly why the cause stayed unproven while several plausible theories got proposed and discarded.
//! The only way to learn where it stalls is to be watching WHILE it stalls.
//!
//! HOW. The frame loop stamps a heartbeat and a PHASE (which part of the frame it is in) into two atomics —
//! two relaxed stores per frame, unmeasurable against a 16ms budget. A separate thread samples them ~4x a
//! second; it is not the frozen thread, so it keeps running and can report. When the heartbeat goes stale past
//! STALL_MS it logs the phase and how long, once per stall, then logs the recovery (or, if the OS kills us
//! first, the stall line is the last thing in the log — which is itself the answer).
//!
//! Reading the output: the phase names the LAST thing the frame loop entered. `gl_swap` means the stall is
//! inside the driver's buffer swap (see the confirmed nvoglv64.dll fault on this machine, and its hybrid
//! AMD + NVIDIA setup) — not our code. Anything else names our code and narrows it to one section.

const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");

/// Frame-loop sections, coarse enough that instrumenting them costs nothing and fine enough to separate
/// "stuck in the graphics driver" from "stuck in our own drawing or input handling".
pub const Phase = enum(u8) {
    idle_start,
    input, // handleWindowChrome / handleKeys / drop + clipboard
    sim, // the SIM.txt control-file probe (file IO on the UI thread)
    draw_chrome, // titlebar + tabbar
    draw_tab, // the active tab's body — the big one
    gl_swap, // rl.endDrawing(): buffer swap + vsync wait. A stall HERE is the driver, not us.

    pub fn name(p: Phase) []const u8 {
        return switch (p) {
            .idle_start => "frame-start",
            .input => "input/keys/drop",
            .sim => "SIM.txt probe",
            .draw_chrome => "draw titlebar+tabs",
            .draw_tab => "draw active tab",
            .gl_swap => "GL endDrawing (driver)",
        };
    }
};

/// A frame that has not ticked in this long is a hang, not slowness. Windows itself calls a window
/// unresponsive at ~5s; report just under that so our line lands BEFORE the OS decides to kill us.
const STALL_MS: i64 = 4_000;
/// Re-log a still-ongoing stall at this cadence, so a 14-minute freeze leaves a visible progression in the
/// log instead of one line at the start that could be mistaken for a blip.
const REPEAT_MS: i64 = 15_000;
const SAMPLE_MS: u64 = 250;

var beat_ms: std.atomic.Value(i64) = .init(0);
var phase_v: std.atomic.Value(u8) = .init(@intFromEnum(Phase.idle_start));
var frames: std.atomic.Value(u64) = .init(0);
var running: std.atomic.Value(bool) = .init(false);
/// How many stalls this process has reported. Exposed because the log alone is not observable from a test
/// (log.zig is a ring drained by a flusher thread that only runs in the real app), and because "did the UI
/// freeze at all today" is a question worth being able to answer cheaply from inside the program.
var stalls: std.atomic.Value(u32) = .init(0);

pub fn stallCount() u32 {
    return stalls.load(.monotonic);
}

/// Called at the top of each frame. Reads the clock ITSELF rather than taking one from the caller: the
/// watcher compares this against its own reading, and the UI thread's convenient clock (rl.getTime, epoch =
/// raylib init) is not the same epoch as Io.Timestamp — mixing them silently produces a nonsense delta and a
/// watchdog that either never fires or never stops. One clock, owned here, is the only safe arrangement.
/// No-op until start() has run.
pub fn beat(p: Phase) void {
    if (!running.load(.acquire)) return;
    beat_ms.store(nowMs(ctx.io), .monotonic);
    phase_v.store(@intFromEnum(p), .monotonic);
}

/// Mark the phase without a new timestamp: use INSIDE a frame so a stall is attributed to the section that
/// was actually running, while the heartbeat keeps measuring from the frame's start.
pub fn mark(p: Phase) void {
    phase_v.store(@intFromEnum(p), .monotonic);
}

pub fn frameDone() void {
    _ = frames.fetchAdd(1, .monotonic);
}

/// Pure decision, split out so the timing rules are unit-tested without threads or a clock.
/// Returns the ms of the stall to report, or null for "nothing to say".
pub fn stallReport(now: i64, last_beat: i64, already_reported_at: i64) ?i64 {
    const stalled = now - last_beat;
    if (stalled < STALL_MS) return null;
    if (already_reported_at != 0 and now - already_reported_at < REPEAT_MS) return null;
    return stalled;
}

const Ctx = struct { io: Io, hang_path: [512]u8 = undefined, hang_len: usize = 0 };
var ctx: Ctx = undefined;

/// Spawn the watcher. Never fails the app: if the thread cannot start we simply have no watchdog.
/// `data_dir` is where the DURABLE stall record goes — see writeHangRecord for why that is not optional.
pub fn start(io: Io, data_dir: []const u8) void {
    if (running.swap(true, .acq_rel)) return; // already started
    ctx = .{ .io = io };
    if (std.fmt.bufPrint(&ctx.hang_path, "{s}/desk-hang.log", .{data_dir})) |p| {
        ctx.hang_len = p.len;
    } else |_| ctx.hang_len = 0;
    beat_ms.store(nowMs(io), .monotonic);
    _ = std.Thread.spawn(.{}, watch, .{}) catch {
        running.store(false, .release);
        log.warn("watchdog: could not start — a UI hang will go unreported", .{});
    };
}

/// Append the stall record straight to disk, opened and closed on the spot.
///
/// THIS IS THE WHOLE POINT, and the first version got it wrong. log.zig is a fixed ring drained by a separate
/// flusher thread, so a line handed to log.warn only reaches the disk if the process lives long enough for the
/// flusher to run. A watchdog exists precisely for the case where the process does NOT survive — the app was
/// terminated mid-stall and the ring died with it, which is exactly what happened: a real freeze, a watchdog
/// running, and not one line to show for it. Buffered evidence of a death is no evidence at all.
///
/// Best-effort and never fatal: if the write fails there is nothing sensible to do about it from in here.
fn writeHangRecord(io: Io, text: []const u8) void {
    if (ctx.hang_len == 0) return;
    const path = ctx.hang_path[0..ctx.hang_len];
    const size: u64 = if (Io.Dir.cwd().statFile(io, path, .{})) |st| st.size else |_| 0;
    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
    defer f.close(io);
    f.writePositionalAll(io, text, size) catch {};
}

pub fn stop() void {
    running.store(false, .release);
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

fn watch() void {
    const io = ctx.io;
    var reported_at: i64 = 0;
    var stall_start: i64 = 0;
    var frames_at_stall: u64 = 0;
    while (running.load(.acquire)) {
        io.sleep(.{ .nanoseconds = SAMPLE_MS * std.time.ns_per_ms }, .awake) catch return;
        const now = nowMs(io);
        const last = beat_ms.load(.monotonic);
        if (stallReport(now, last, reported_at)) |stalled| {
            if (reported_at == 0) {
                stall_start = last;
                frames_at_stall = frames.load(.monotonic);
            }
            reported_at = now;
            _ = stalls.fetchAdd(1, .monotonic);
            const p: Phase = @enumFromInt(phase_v.load(.monotonic));
            // The single most useful line this program can print about a freeze. Written BOTH ways on purpose:
            // to the ring (so it sits in context beside the surrounding activity when the app survives) and
            // straight to disk (so it survives when it does not).
            log.warn("watchdog: UI FROZEN {d}ms in phase '{s}' (frame #{d}) — the window is not pumping messages; Windows closes it at ~5s of this", .{ stalled, p.name(), frames_at_stall });
            var rb: [320]u8 = undefined;
            if (std.fmt.bufPrint(&rb, "UI FROZEN {d}ms  phase='{s}'  frame=#{d}  stall_no={d}\n", .{ stalled, p.name(), frames_at_stall, stalls.load(.monotonic) })) |line| {
                writeHangRecord(io, line);
            } else |_| {}
        } else if (reported_at != 0 and now - last < STALL_MS) {
            const total = last - stall_start;
            log.warn("watchdog: UI resumed after {d}ms frozen", .{total});
            var rb: [160]u8 = undefined;
            if (std.fmt.bufPrint(&rb, "UI resumed after {d}ms frozen\n", .{total})) |line| writeHangRecord(io, line) else |_| {}
            reported_at = 0;
        }
    }
}

// ------------------------------------------------------------------------------------------------- tests

test "stallReport: quiet under a healthy frame rate, fires once per stall, repeats slowly" {
    // a 16ms frame is silence
    try std.testing.expect(stallReport(1_000, 984, 0) == null);
    // just under the threshold is still silence — slow is not hung
    try std.testing.expect(stallReport(10_000, 10_000 - (STALL_MS - 1), 0) == null);
    // past the threshold reports the real elapsed time
    try std.testing.expectEqual(@as(?i64, STALL_MS), stallReport(10_000, 10_000 - STALL_MS, 0));
    try std.testing.expectEqual(@as(?i64, 9_000), stallReport(20_000, 11_000, 0));
    // having just reported, stay quiet until REPEAT_MS has passed (no log spam during a long freeze)
    try std.testing.expect(stallReport(20_000, 11_000, 19_000) == null);
    try std.testing.expectEqual(@as(?i64, 9_000), stallReport(20_000, 11_000, 20_000 - REPEAT_MS));
}

test "Phase.name: every phase is describable, and the driver one is distinguishable" {
    inline for (@typeInfo(Phase).@"enum".fields) |f| {
        const p: Phase = @enumFromInt(f.value);
        try std.testing.expect(p.name().len > 0);
    }
    // the load-bearing distinction: a stall in the swap is the graphics driver, not our code
    try std.testing.expect(std.mem.indexOf(u8, Phase.gl_swap.name(), "driver") != null);
}

test "watchdog thread: notices a frozen caller, then notices recovery (real thread + real clock)" {
    // The pure rule is tested above; THIS proves the wiring — that a separate thread, using the same clock
    // the frame loop stamps, actually observes a stall it did not cause. Asserted on the counter rather than
    // the log, because log.zig is a ring drained by a flusher that only runs in the real app.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io2 = threaded.io();
    const before = stallCount();
    start(io2, ".");
    defer stop();
    Io.Dir.cwd().deleteFile(io2, "./desk-hang.log") catch {};
    defer Io.Dir.cwd().deleteFile(io2, "./desk-hang.log") catch {};
    beat(.draw_tab);
    // freeze the "frame loop": stop beating for longer than the threshold
    io2.sleep(.{ .nanoseconds = @as(u64, @intCast(STALL_MS)) * std.time.ns_per_ms + 1500 * std.time.ns_per_ms }, .awake) catch {};
    try std.testing.expect(stallCount() > before); // it saw the freeze
    // resume; the watcher must fall back out of the stall state and not keep counting
    beat(.idle_start);
    const after_resume = stallCount();
    io2.sleep(.{ .nanoseconds = 1000 * std.time.ns_per_ms }, .awake) catch {};
    beat(.idle_start);
    io2.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
    try std.testing.expectEqual(after_resume, stallCount()); // a healthy loop is silent
    // and the record must be ON DISK, not only in the ring the process takes to its grave
    const rec = Io.Dir.cwd().readFileAlloc(io2, "./desk-hang.log", std.testing.allocator, .limited(4096)) catch "";
    defer if (rec.len > 0) std.testing.allocator.free(rec);
    try std.testing.expect(std.mem.indexOf(u8, rec, "UI FROZEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec, "draw active tab") != null);
}
