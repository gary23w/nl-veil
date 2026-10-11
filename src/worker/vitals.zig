//! vitals.zig — the app's own resource readings: sampled every few seconds, logged once a window and at once on a
//! spike, and served as JSON, so the next "the app is lagging" starts from the log instead of from perf counters.
//!
//! WHY. The 2026-10-11 lag hunt was done by hand with Windows perf counters, and both answers were numbers the app
//! could have reported itself: Windows Defender (MsMpEng.exe) re-reading the training-set files after every model call
//! (worker/dataset.zig, ROLLING PARTS), and every thread stack committing 16 MiB up front (threads.zig). So a sample
//! holds this process's commit charge, working set, thread and handle counts and I/O bytes; the system's commit charge
//! against its limit and its free RAM; and Defender's read bytes, the signal that exposed the rescans. Logged lines also
//! break the threads down by name: threads.zig names each thread it starts "veil:<role>", httpz's workers are
//! "veil:http", and an unnamed thread is one of std.Io.Threaded's pool threads.
//!
//! WHAT IS LOGGED. One line at start, one a window (log_every_s rounded to whole samples, windowMs) carrying that
//! window's deltas, and a warn line the moment a sample crosses a spike threshold against the sample before it
//! (spikes(), thresholds below). Each spike kind warns at most once per window, so a machine that stays short of RAM
//! gets one warning a window, not one every 5 s.
//!
//! PLAIN THREAD. loop() is a thread body (main.zig: threads.spawn("vitals", vitals.loop, .{ctx})), so nothing here
//! touches the Io runtime. It sleeps through kernel32 Sleep or nanosleep, never io.sleep: a plain thread parked on
//! Io.Threaded's thread alert can wedge for good (desk/src/nap.zig has the 2026-09-02 story). The ring's lock is a
//! spinlock, not std.Io.Mutex, and the readers are raw OS calls: NtQuerySystemInformation and K32GetPerformanceInfo on
//! Windows, /proc through raw syscalls on Linux. Other systems report nothing.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.vitals);

/// The Windows reader walks the x64 layout of SYSTEM_PROCESS_INFORMATION; other Windows arches report nothing.
const win_supported = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;
/// Whether sample() can answer on this build at all.
pub const supported = win_supported or builtin.os.tag == .linux;

const MiB: u64 = 1 << 20;
const GiB: u64 = 1 << 30;

/// One reading. Bytes everywhere; the read/write counters are cumulative, exactly as the OS reports them.
pub const Sample = struct {
    /// Wall clock, Unix milliseconds.
    t_ms: i64,
    /// This process's commit charge. Windows: PagefileUsage, i.e. private bytes. Linux: RssAnon + VmSwap (see lin).
    own_commit: u64,
    own_ws: u64,
    own_threads: u32,
    own_handles: u32,
    /// Windows counts every byte the process reads or writes through I/O calls: files, but also pipes and sockets.
    /// Linux counts storage bytes only (/proc/self/io read_bytes, write_bytes). Hence "io", not "disk", in the line.
    own_read: u64,
    own_write: u64,
    /// The system's commit charge and the limit it cannot pass (RAM + page files on Windows).
    sys_commit: u64,
    sys_limit: u64,
    /// RAM available without paging anything out.
    sys_avail: u64,
    /// MsMpEng.exe's cumulative read bytes; 0 unless defender_found.
    defender_read: u64,
    defender_found: bool,
    /// Whether sys_limit is a limit the OS enforces. Always on Windows; on Linux only under strict overcommit
    /// (vm.overcommit_memory = 2). Under the default heuristic, Committed_AS can sit past RAM + swap for good,
    /// so near_limit would warn every window about a ceiling that refuses nothing (found in review, 2026-10-11).
    limit_enforced: bool = true,
};

// ------------------------------------------------------------------------------------------------ spikes

/// Defender read this much between two samples. A rescan of one of the old 500 MB training-set files is twice that.
pub const spike_defender_read: u64 = 256 * MiB;
/// This process's commit charge grew by this much between two samples.
pub const spike_commit_growth: u64 = 128 * MiB;
/// This process gained this many threads between two samples.
pub const spike_thread_growth: u32 = 16;
/// Less RAM than this is available.
pub const low_ram_below: u64 = 1 * GiB;
/// The system commit charge reached this percentage of an ENFORCED limit (Sample.limit_enforced): past it,
/// allocations fail outright.
pub const near_limit_pct: u64 = 95;

pub const Spike = struct {
    defender: bool = false,
    commit: bool = false,
    threads: bool = false,
    low_ram: bool = false,
    near_limit: bool = false,

    pub fn any(s: Spike) bool {
        inline for (@typeInfo(Spike).@"struct".fields) |f| if (@field(s, f.name)) return true;
        return false;
    }

    /// "spike: defender+low_ram", for formatLine's why.
    pub fn why(s: Spike, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll("spike:") catch {};
        var sep: []const u8 = " ";
        inline for (@typeInfo(Spike).@"struct".fields) |f| {
            if (@field(s, f.name)) {
                w.writeAll(sep) catch {};
                w.writeAll(f.name) catch {};
                sep = "+";
            }
        }
        return w.buffered();
    }
};

const spike_kinds = @typeInfo(Spike).@"struct".fields.len;

/// Which thresholds `cur` crossed against `prev`. A counter that went DOWN (Defender restarted, so its counter did)
/// is no spike.
pub fn spikes(prev: Sample, cur: Sample) Spike {
    return .{
        .defender = prev.defender_found and cur.defender_found and cur.defender_read -| prev.defender_read >= spike_defender_read,
        .commit = cur.own_commit -| prev.own_commit >= spike_commit_growth,
        .threads = cur.own_threads -| prev.own_threads >= spike_thread_growth,
        .low_ram = cur.sys_avail < low_ram_below,
        .near_limit = cur.limit_enforced and cur.sys_limit > 0 and @as(u128, cur.sys_commit) * 100 >= @as(u128, cur.sys_limit) * near_limit_pct,
    };
}

// ------------------------------------------------------------------------------------------------ thread names

const unnamed = "(unnamed)";

/// Threads counted by name, in fixed storage: up to `max` distinct names, each cut to `name_max` bytes. Threads whose
/// name found no free slot are counted in `overflow`.
pub const Names = struct {
    pub const max = 32;
    pub const name_max = 40;

    pub const Entry = struct {
        buf: [name_max]u8 = undefined,
        len: u8 = 0,
        count: u32 = 0,

        pub fn name(e: *const Entry) []const u8 {
            return e.buf[0..e.len];
        }
    };

    entries: [max]Entry = undefined,
    len: usize = 0,
    overflow: u32 = 0,

    pub fn add(n: *Names, name: []const u8, count: u32) void {
        const key = name[0..@min(name.len, name_max)];
        for (n.entries[0..n.len]) |*e| {
            if (std.mem.eql(u8, e.name(), key)) {
                e.count += count;
                return;
            }
        }
        if (n.len == max) {
            n.overflow += count;
            return;
        }
        const e = &n.entries[n.len];
        e.* = .{ .len = @intCast(key.len), .count = count };
        @memcpy(e.buf[0..key.len], key);
        n.len += 1;
    }

    pub fn slice(n: *const Names) []const Entry {
        return n.entries[0..n.len];
    }

    pub fn total(n: *const Names) u64 {
        var sum: u64 = n.overflow;
        for (n.slice()) |*e| sum += e.count;
        return sum;
    }

    /// Most threads first, then by name, so a line's first few names are the ones that matter.
    pub fn sort(n: *Names) void {
        std.mem.sort(Entry, n.entries[0..n.len], {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.buf[0..a.len], b.buf[0..b.len]);
            }
        }.less);
    }
};

/// Counts this process's threads by description into `out` (reset first), sorted most threads first. An empty
/// description counts as "(unnamed)". Leaves `out` empty where sample() is unsupported or the query failed.
pub fn threadNames(gpa: std.mem.Allocator, out: *Names) void {
    out.* = .{};
    switch (builtin.os.tag) {
        .windows => if (comptime win_supported) win.threadNames(gpa, out),
        .linux => lin.threadNames(out),
        else => {},
    }
    out.sort();
}

/// `in` as printable ASCII (anything else becomes '?'), cut to a name slot; "(unnamed)" when empty.
fn printable(in: []const u8, out: *[Names.name_max]u8) []const u8 {
    const n = @min(in.len, out.len);
    for (in[0..n], 0..) |c, i| out[i] = if (c >= 0x20 and c < 0x7f) c else '?';
    return if (n == 0) unnamed else out[0..n];
}

// ------------------------------------------------------------------------------------------------ sampling

/// One reading of this process and the system; null where unsupported or when the query failed.
pub fn sample(gpa: std.mem.Allocator) ?Sample {
    return switch (builtin.os.tag) {
        .windows => if (comptime win_supported) win.sample(gpa) else null,
        .linux => lin.sample(),
        else => null,
    };
}

// ------------------------------------------------------------------------------------------------ the log line

/// How many names a line spells out; the rest are summed into "+N more" (N threads).
pub const line_names = 8;

/// One log line, e.g.
///   vitals[60s]: veil commit 231 MB, ws 172 MB, threads 41 (veil:http 28, (unnamed) 9, +4 more), handles 812,
///   io r 2.1 MB w 0.4 MB | system commit 37.1/45.6 GB, 5.5 GB free | defender read 1.2 GB
/// The io and defender figures are deltas since `prev` and are left out without it (defender also when either sample
/// did not find it). Names print in their stored order. Never fails: a line too long for `buf` is cut at its end.
pub fn formatLine(buf: []u8, prev: ?Sample, cur: Sample, names: ?*const Names, why: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeLine(&w, prev, cur, names, why) catch {};
    return w.buffered();
}

fn writeLine(w: *std.Io.Writer, prev: ?Sample, cur: Sample, names: ?*const Names, why: []const u8) std.Io.Writer.Error!void {
    try w.print("vitals[{s}]: veil commit ", .{why});
    try writeSize(w, cur.own_commit);
    try w.writeAll(", ws ");
    try writeSize(w, cur.own_ws);
    try w.print(", threads {d}", .{cur.own_threads});
    if (names) |n| if (n.len > 0 or n.overflow > 0) {
        const shown = @min(n.len, line_names);
        try w.writeAll(" (");
        for (n.slice()[0..shown], 0..) |*e, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s} {d}", .{ e.name(), e.count });
        }
        var rest: u64 = n.overflow;
        for (n.slice()[shown..]) |*e| rest += e.count;
        if (rest > 0) try w.print("{s}+{d} more", .{ if (shown > 0) ", " else "", rest });
        try w.writeAll(")");
    };
    try w.print(", handles {d}", .{cur.own_handles});
    if (prev) |p| {
        try w.writeAll(", io r ");
        try writeSize(w, cur.own_read -| p.own_read);
        try w.writeAll(" w ");
        try writeSize(w, cur.own_write -| p.own_write);
    }
    try w.writeAll(" | system commit ");
    const unit = unitOf(@max(cur.sys_commit, cur.sys_limit));
    try writeAmount(w, cur.sys_commit, unit);
    try w.writeByte('/');
    try writeAmount(w, cur.sys_limit, unit);
    try w.writeAll(unitName(unit));
    try w.writeAll(", ");
    try writeSize(w, cur.sys_avail);
    try w.writeAll(" free");
    if (prev) |p| if (p.defender_found and cur.defender_found) {
        try w.writeAll(" | defender read ");
        try writeSize(w, cur.defender_read -| p.defender_read);
    };
}

/// GB from 1000 MiB up, so a size never prints as four digits of MB (MB and GB are 2^20 and 2^30 bytes here).
fn unitOf(n: u64) u64 {
    return if (n >= 1000 * MiB) GiB else MiB;
}

fn unitName(unit: u64) []const u8 {
    return if (unit == GiB) " GB" else " MB";
}

/// One decimal below 100 units ("2.1", "37.1"), whole units from 100 up ("231"); rounded half up.
fn writeAmount(w: *std.Io.Writer, n: u64, unit: u64) std.Io.Writer.Error!void {
    const tenths = (@as(u128, n) * 10 + unit / 2) / unit;
    if (tenths >= 1000) return w.print("{d}", .{(@as(u128, n) + unit / 2) / unit});
    try w.print("{d}.{d}", .{ tenths / 10, tenths % 10 });
}

fn writeSize(w: *std.Io.Writer, n: u64) std.Io.Writer.Error!void {
    const unit = unitOf(n);
    try writeAmount(w, n, unit);
    try w.writeAll(unitName(unit));
}

// ------------------------------------------------------------------------------------------------ the thread

/// Samples kept for renderJson: ten minutes at the default 5 s.
pub const ring_cap = 120;

/// The thread's state. The caller owns it (heap or static: it holds the ring, ~12 KB) and keeps it alive until the
/// thread has been joined after `stop`.
pub const Ctx = struct {
    /// Must be thread-safe: the snapshot buffers are allocated on the vitals thread.
    gpa: std.mem.Allocator,
    /// Seconds between window lines (logEvery reads NL_VITALS_LOG_S), rounded to whole samples (windowMs).
    log_every_s: u32 = 60,
    /// At least 100.
    sample_every_ms: u32 = 5000,
    stop: std.atomic.Value(bool) = .init(false),

    ring_lock: std.atomic.Value(bool) = .init(false),
    ring: [ring_cap]Sample = undefined,
    ring_len: usize = 0,
    ring_next: usize = 0,

    pub fn push(ctx: *Ctx, s: Sample) void {
        ctx.acquire();
        defer ctx.release();
        ctx.ring[ctx.ring_next] = s;
        ctx.ring_next = (ctx.ring_next + 1) % ring_cap;
        if (ctx.ring_len < ring_cap) ctx.ring_len += 1;
    }

    /// The kept samples, oldest first and newest last, copied into `out`.
    pub fn recent(ctx: *Ctx, out: *[ring_cap]Sample) []Sample {
        ctx.acquire();
        defer ctx.release();
        const n = ctx.ring_len;
        const start = (ctx.ring_next + ring_cap - n) % ring_cap;
        for (0..n) |i| out[i] = ctx.ring[(start + i) % ring_cap];
        return out[0..n];
    }

    fn acquire(ctx: *Ctx) void {
        while (ctx.ring_lock.swap(true, .acquire)) std.Thread.yield() catch {};
    }

    fn release(ctx: *Ctx) void {
        ctx.ring_lock.store(false, .release);
    }
};

/// The sample period loop() keeps: Ctx.sample_every_ms, at least 100.
fn periodMs(sample_every_ms: u32) u32 {
    return @max(sample_every_ms, 100);
}

/// How many samples one window spans: log_every_s rounded to the nearest whole number of sample periods, at least
/// one. The window is counted in samples, not by the wall clock, so a clock step cannot stretch or skip one.
fn windowSamples(log_every_s: u32, every_ms: u32) u64 {
    return @max(1, (@as(u64, log_every_s) * 1000 + every_ms / 2) / every_ms);
}

/// The span a window line's deltas really cover, in ms. log_every_s need not be a whole number of sample periods
/// (NL_VITALS_LOG_S=8 at 5 s a sample makes a 10 s window), so this, not log_every_s, labels the line and fills
/// renderJson's "log_every_s".
pub fn windowMs(log_every_s: u32, sample_every_ms: u32) u64 {
    const every = periodMs(sample_every_ms);
    return windowSamples(log_every_s, every) * every;
}

/// `ms` as seconds, exactly and with no trailing zeros: "60", "7.5", "0.25", "1.005".
fn writeSeconds(w: *std.Io.Writer, ms: u64) std.Io.Writer.Error!void {
    try w.print("{d}", .{ms / 1000});
    var frac: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&frac, "{d:0>3}", .{ms % 1000}) catch unreachable; // below 1000: three digits
    const digits = std.mem.trimEnd(u8, &frac, "0");
    if (digits.len > 0) try w.print(".{s}", .{digits});
}

/// A window line's label, "60s" or "7.5s", from windowMs.
fn windowLabel(buf: []u8, window_ms: u64) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeSeconds(&w, window_ms) catch return "window";
    w.writeByte('s') catch return "window";
    return w.buffered();
}

/// The thread body. Runs until ctx.stop is set, answering it within 200 ms.
pub fn loop(ctx: *Ctx) void {
    const every_ms = periodMs(ctx.sample_every_ms);
    const window = windowSamples(ctx.log_every_s, every_ms);
    var label_buf: [32]u8 = undefined;
    const window_label = windowLabel(&label_buf, windowMs(ctx.log_every_s, ctx.sample_every_ms));
    var tick: u64 = 0;
    var prev: ?Sample = null; // the sample before this one: spikes are measured against it
    var base: ?Sample = null; // the sample the last window line ended on: that line's deltas start here
    var next_line: u64 = 0;
    var quiet_until: [spike_kinds]u64 = @splat(0);
    var names: Names = .{};
    var line: [1024]u8 = undefined;
    var why: [64]u8 = undefined;

    while (!ctx.stop.load(.acquire)) : (tick += 1) {
        if (sample(ctx.gpa)) |cur| {
            ctx.push(cur);
            // No spike checks in the first window: the first sample lands mid-startup (a handful of threads, a few
            // MB), so the second always "grew" by the whole server. Measured 2026-10-11: a false commit+threads
            // warning on every launch. The window line at the end of startup still carries the numbers.
            if (prev != null and tick >= window) {
                const p = prev.?;
                var sp = spikes(p, cur);
                inline for (@typeInfo(Spike).@"struct".fields, 0..) |f, i| {
                    if (@field(sp, f.name)) {
                        if (tick < quiet_until[i]) @field(sp, f.name) = false else quiet_until[i] = tick + window;
                    }
                }
                if (sp.any()) {
                    threadNames(ctx.gpa, &names);
                    log.warn("{s}", .{formatLine(&line, p, cur, &names, sp.why(&why))});
                }
            }
            if (base == null or tick >= next_line) {
                threadNames(ctx.gpa, &names);
                log.info("{s}", .{formatLine(&line, base, cur, &names, if (base == null) "start" else window_label)});
                base = cur;
                next_line = tick + window;
            }
            prev = cur;
        }
        var left = every_ms;
        while (left > 0 and !ctx.stop.load(.acquire)) {
            const step = @min(left, 200);
            sleepMs(step);
            left -= step;
        }
    }
}

/// {"samples":[{...},...],"threads":{"name":count,...},"log_every_s":60,"sample_every_ms":5000}: the ring, oldest
/// first, and the threads counted by name right now. log_every_s and sample_every_ms are what loop() really runs on,
/// not what Ctx asked for: the window's span (windowMs, in seconds, a decimal only when it is not whole) and the
/// sample period (at least 100 ms).
pub fn renderJson(ctx: *Ctx, gpa: std.mem.Allocator) ![]u8 {
    var kept: [ring_cap]Sample = undefined;
    const list = ctx.recent(&kept);
    var names: Names = .{};
    threadNames(gpa, &names);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeJson(&aw.writer, list, &names, windowMs(ctx.log_every_s, ctx.sample_every_ms), periodMs(ctx.sample_every_ms)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeJson(w: *std.Io.Writer, list: []const Sample, names: *const Names, window_ms: u64, sample_every_ms: u32) std.Io.Writer.Error!void {
    try w.writeAll("{\"samples\":[");
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"t_ms\":{d},\"own_commit\":{d},\"own_ws\":{d},\"own_threads\":{d},\"own_handles\":{d},\"own_read\":{d}," ++
                "\"own_write\":{d},\"sys_commit\":{d},\"sys_limit\":{d},\"sys_avail\":{d},\"defender_read\":{d},\"defender_found\":{s}}}",
            .{
                s.t_ms,      s.own_commit, s.own_ws,    s.own_threads, s.own_handles,   s.own_read,
                s.own_write, s.sys_commit, s.sys_limit, s.sys_avail,   s.defender_read, if (s.defender_found) "true" else "false",
            },
        );
    }
    try w.writeAll("],\"threads\":{");
    // Names hold only what threads.zig and the OS wrote, but a key is still cut down to bytes that need no escaping.
    // Two names that clean to the same key are merged, and a thread literally named "(other)" (every byte of it
    // survives cleaning) is counted under the overflow's key instead of beside it, so the object never repeats a key.
    var clean: Names = .{};
    var other: u64 = names.overflow;
    for (names.slice()) |*e| {
        var b: [Names.name_max]u8 = undefined;
        for (e.name(), 0..) |c, i| b[i] = if (jsonNameByte(c)) c else '?';
        const key = b[0..e.len];
        if (std.mem.eql(u8, key, other_key)) other += e.count else clean.add(key, e.count);
    }
    for (clean.slice(), 0..) |*e, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":{d}", .{ e.name(), e.count });
    }
    other += clean.overflow;
    if (other > 0) try w.print("{s}\"" ++ other_key ++ "\":{d}", .{ if (clean.len > 0) "," else "", other });
    try w.writeAll("},\"log_every_s\":");
    try writeSeconds(w, window_ms);
    try w.print(",\"sample_every_ms\":{d}}}", .{sample_every_ms});
}

/// The threads object's key for the threads no name slot held.
const other_key = "(other)";

fn jsonNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ":._()+ -", c) != null;
}

// ------------------------------------------------------------------------------------------------ config

/// NL_VITALS: on unless "0", "off" or "false" (any case).
pub fn enabled(v: ?[]const u8) bool {
    const s = std.mem.trim(u8, v orelse return true, " \t\r\n");
    for ([_][]const u8{ "0", "off", "false" }) |off| if (std.ascii.eqlIgnoreCase(s, off)) return false;
    return true;
}

/// NL_VITALS_LOG_S: seconds between window lines, 60 by default, held to 5..3600.
pub fn logEvery(v: ?[]const u8) u32 {
    const s = std.mem.trim(u8, v orelse return 60, " \t\r\n");
    if (s.len == 0) return 60;
    for (s) |c| if (!std.ascii.isDigit(c)) return 60; // signs, units, words: not a number of seconds
    const n = std.fmt.parseInt(u64, s, 10) catch return 3600; // digits only, so the one failure left is overflow
    return @intCast(std.math.clamp(n, 5, 3600));
}

// ------------------------------------------------------------------------------------------------ OS plumbing

/// A sleep that never parks on the Io runtime: kernel32 Sleep is a non-alertable NtDelayExecution.
fn sleepMs(ms: u32) void {
    switch (builtin.os.tag) {
        .windows => win.Sleep(ms),
        .linux => {
            const ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
            _ = std.os.linux.nanosleep(&ts, null);
        },
        else => {
            const ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
            _ = std.c.nanosleep(&ts, null);
        },
    }
}

fn wallMs() i64 {
    switch (builtin.os.tag) {
        // 100 ns ticks since 1601
        .windows => return @divTrunc(std.os.windows.ntdll.RtlGetSystemTimePrecise() - 116_444_736_000_000_000, 10_000),
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            if (std.os.linux.errno(std.os.linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
            return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
        },
        else => return 0,
    }
}

/// The x64 layouts NtQuerySystemInformation(SystemProcessInformation) returns (phnt's ntexapi.h). Plain types, so the
/// offsets can be checked on any 64-bit target.
const UNICODE_STRING = extern struct {
    Length: u16, // bytes, not characters
    MaximumLength: u16,
    Buffer: ?[*]const u16,
};

const SYSTEM_PROCESS_INFORMATION = extern struct {
    NextEntryOffset: u32,
    NumberOfThreads: u32,
    WorkingSetPrivateSize: i64,
    HardFaultCount: u32,
    NumberOfThreadsHighWatermark: u32,
    CycleTime: u64,
    CreateTime: i64,
    UserTime: i64,
    KernelTime: i64,
    ImageName: UNICODE_STRING,
    BasePriority: i32,
    UniqueProcessId: usize,
    InheritedFromUniqueProcessId: usize,
    HandleCount: u32,
    SessionId: u32,
    UniqueProcessKey: usize,
    PeakVirtualSize: usize,
    VirtualSize: usize,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
    PrivatePageCount: usize,
    ReadOperationCount: i64,
    WriteOperationCount: i64,
    OtherOperationCount: i64,
    ReadTransferCount: i64,
    WriteTransferCount: i64,
    OtherTransferCount: i64,
    // NumberOfThreads SYSTEM_THREAD_INFORMATION follow
};

const CLIENT_ID = extern struct {
    UniqueProcess: usize,
    UniqueThread: usize,
};

const SYSTEM_THREAD_INFORMATION = extern struct {
    KernelTime: i64,
    UserTime: i64,
    CreateTime: i64,
    WaitTime: u32,
    StartAddress: usize,
    ClientId: CLIENT_ID,
    Priority: i32,
    BasePriority: i32,
    ContextSwitches: u32,
    ThreadState: u32,
    WaitReason: u32,
};

fn expectOffset(comptime T: type, comptime field: []const u8, comptime want: usize) void {
    if (@offsetOf(T, field) != want) @compileError(std.fmt.comptimePrint("{s}.{s} is at {d}, the x64 layout has it at {d}", .{ @typeName(T), field, @offsetOf(T, field), want }));
}

fn checkLayout() void {
    const P = SYSTEM_PROCESS_INFORMATION;
    expectOffset(P, "NextEntryOffset", 0);
    expectOffset(P, "NumberOfThreads", 4);
    expectOffset(P, "ImageName", 56);
    expectOffset(UNICODE_STRING, "Buffer", 8);
    expectOffset(P, "UniqueProcessId", 80);
    expectOffset(P, "HandleCount", 96);
    expectOffset(P, "WorkingSetSize", 144);
    expectOffset(P, "PagefileUsage", 184);
    expectOffset(P, "PrivatePageCount", 200);
    expectOffset(P, "ReadTransferCount", 232);
    expectOffset(P, "WriteTransferCount", 240);
    if (@sizeOf(P) != 256) @compileError("SYSTEM_PROCESS_INFORMATION must be 256 bytes");
    const T = SYSTEM_THREAD_INFORMATION;
    expectOffset(T, "ClientId", 40);
    // UniqueThread is ClientId's SECOND handle, at 48: 40 is UniqueProcess. The test "the snapshot's own thread list
    // holds the calling thread" proves the pair against the running system.
    if (@offsetOf(T, "ClientId") + @offsetOf(CLIENT_ID, "UniqueThread") != 48) @compileError("ClientId.UniqueThread must be at 48");
    if (@sizeOf(T) != 80) @compileError("SYSTEM_THREAD_INFORMATION must be 80 bytes");
}

comptime {
    if (@sizeOf(usize) == 8) checkLayout();
}

const win = struct {
    const windows = std.os.windows;
    const SPI = SYSTEM_PROCESS_INFORMATION;
    const STI = SYSTEM_THREAD_INFORMATION;

    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    extern "kernel32" fn K32GetPerformanceInfo(info: *PERFORMANCE_INFORMATION, cb: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn OpenThread(access: u32, inherit: windows.BOOL, tid: u32) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetThreadDescription(thread: windows.HANDLE, desc: *?[*:0]u16) callconv(.winapi) i32;
    extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    // the tests name a thread with these, as threads.zig does
    extern "kernel32" fn SetThreadDescription(thread: windows.HANDLE, desc: [*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) windows.HANDLE;

    const THREAD_QUERY_LIMITED_INFORMATION: u32 = 0x0800;

    /// Counts in PAGES, except PageSize.
    const PERFORMANCE_INFORMATION = extern struct {
        cb: u32,
        CommitTotal: usize,
        CommitLimit: usize,
        CommitPeak: usize,
        PhysicalTotal: usize,
        PhysicalAvailable: usize,
        SystemCache: usize,
        KernelTotal: usize,
        KernelPaged: usize,
        KernelNonpaged: usize,
        PageSize: usize,
        HandleCount: u32,
        ProcessCount: u32,
        ThreadCount: u32,
    };

    /// The size the last snapshot needed, so the next one usually fits on its first try.
    var size_hint: std.atomic.Value(usize) = .init(512 << 10);

    const Snapshot = struct {
        buf: []align(8) u8,
        len: usize, // bytes the kernel filled
    };

    /// Every process on the machine with its threads: the one query that reaches Defender's counters without a
    /// handle to it (MsMpEng is a protected process).
    fn snapshot(gpa: std.mem.Allocator) ?Snapshot {
        var size: usize = @max(size_hint.load(.monotonic), 512 << 10);
        for (0..4) |_| {
            const buf = gpa.alignedAlloc(u8, .@"8", size) catch return null;
            var ret: u32 = 0;
            const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
            switch (windows.ntdll.NtQuerySystemInformation(.Process, @ptrCast(buf.ptr), len, &ret)) {
                .SUCCESS => {
                    size_hint.store(size, .monotonic);
                    return .{ .buf = buf, .len = if (ret == 0) buf.len else @min(ret, buf.len) };
                },
                .INFO_LENGTH_MISMATCH => {
                    gpa.free(buf);
                    // processes and threads come and go between the two calls, hence the margin
                    size = if (ret > size) @as(usize, ret) + (64 << 10) else size * 2;
                },
                else => {
                    gpa.free(buf);
                    return null;
                },
            }
        }
        return null;
    }

    const Proc = struct { off: usize, p: SPI };

    const Walk = struct {
        s: *const Snapshot,
        off: ?usize = 0,

        fn next(it: *Walk) ?Proc {
            const off = it.off orelse return null;
            if (off > it.s.len or it.s.len - off < @sizeOf(SPI)) {
                it.off = null;
                return null;
            }
            // copied out: nothing promises an entry is aligned for a pointer cast
            const p = std.mem.bytesToValue(SPI, it.s.buf[off..][0..@sizeOf(SPI)]);
            it.off = if (p.NextEntryOffset == 0) null else off + p.NextEntryOffset;
            return .{ .off = off, .p = p };
        }
    };

    fn findOwn(s: *const Snapshot) ?Proc {
        const me: usize = windows.GetCurrentProcessId();
        var walk: Walk = .{ .s = s };
        while (walk.next()) |e| if (e.p.UniqueProcessId == me) return e;
        return null;
    }

    fn threadAt(s: *const Snapshot, proc: Proc, i: usize) ?STI {
        const off = proc.off + @sizeOf(SPI) + i * @sizeOf(STI);
        if (off > s.len or s.len - off < @sizeOf(STI)) return null;
        return std.mem.bytesToValue(STI, s.buf[off..][0..@sizeOf(STI)]);
    }

    /// The image name equals `want` (ASCII), ignoring case. The name's buffer lives inside the snapshot; one that
    /// points anywhere else is not trusted.
    fn imageIs(s: *const Snapshot, name: UNICODE_STRING, comptime want: []const u8) bool {
        if (name.Length != want.len * 2) return false;
        const p = name.Buffer orelse return false;
        const start = @intFromPtr(p) -% @intFromPtr(s.buf.ptr);
        if (start > s.len or s.len - start < want.len * 2) return false;
        const bytes = s.buf[start..][0 .. want.len * 2];
        for (want, 0..) |c, i| {
            const u = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
            if (u >= 0x80 or std.ascii.toLower(@intCast(u)) != std.ascii.toLower(c)) return false;
        }
        return true;
    }

    fn counter(v: i64) u64 {
        return if (v < 0) 0 else @intCast(v);
    }

    fn sample(gpa: std.mem.Allocator) ?Sample {
        const snap = snapshot(gpa) orelse return null;
        defer gpa.free(snap.buf);
        const me: usize = windows.GetCurrentProcessId();
        var own: ?SPI = null;
        var defender: ?SPI = null;
        var walk: Walk = .{ .s = &snap };
        while (walk.next()) |e| {
            if (e.p.UniqueProcessId == me) {
                own = e.p;
            } else if (defender == null and imageIs(&snap, e.p.ImageName, "MsMpEng.exe")) {
                defender = e.p;
            }
        }
        const o = own orelse return null;
        var perf = std.mem.zeroes(PERFORMANCE_INFORMATION);
        perf.cb = @sizeOf(PERFORMANCE_INFORMATION);
        if (!K32GetPerformanceInfo(&perf, @sizeOf(PERFORMANCE_INFORMATION)).toBool()) return null;
        const page: u64 = perf.PageSize;
        return .{
            .t_ms = wallMs(),
            .own_commit = o.PagefileUsage,
            .own_ws = o.WorkingSetSize,
            .own_threads = o.NumberOfThreads,
            .own_handles = o.HandleCount,
            .own_read = counter(o.ReadTransferCount),
            .own_write = counter(o.WriteTransferCount),
            .sys_commit = @as(u64, perf.CommitTotal) * page,
            .sys_limit = @as(u64, perf.CommitLimit) * page,
            .sys_avail = @as(u64, perf.PhysicalAvailable) * page,
            .defender_read = if (defender) |d| counter(d.ReadTransferCount) else 0,
            .defender_found = defender != null,
        };
    }

    fn threadNames(gpa: std.mem.Allocator, out: *Names) void {
        const snap = snapshot(gpa) orelse return;
        defer gpa.free(snap.buf);
        const own = findOwn(&snap) orelse return;
        for (0..own.p.NumberOfThreads) |i| {
            const t = threadAt(&snap, own, i) orelse break;
            // a thread that exited since the snapshot fails to open and is not counted
            const h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, .FALSE, @truncate(t.ClientId.UniqueThread)) orelse continue;
            defer windows.CloseHandle(h);
            var desc: ?[*:0]u16 = null;
            if (GetThreadDescription(h, &desc) < 0) desc = null;
            defer {
                if (desc) |d| _ = LocalFree(@ptrCast(d));
            }
            var clean: [Names.name_max]u8 = undefined;
            out.add(if (desc) |d| asciiName(d, &clean) else unnamed, 1);
        }
    }

    /// A thread description as ASCII: anything else is '?', one per character (a surrogate pair's low half is
    /// dropped). Empty is "(unnamed)".
    fn asciiName(d: [*:0]const u16, out: *[Names.name_max]u8) []const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (d[i] != 0 and n < out.len) : (i += 1) {
            const u = d[i];
            if (u >= 0xDC00 and u <= 0xDFFF) continue;
            out[n] = if (u >= 0x20 and u < 0x7f) @intCast(u) else '?';
            n += 1;
        }
        return if (n == 0) unnamed else out[0..n];
    }
};

/// Linux reads /proc through raw syscalls (no libc needed, no Io).
const lin = struct {
    const linux = std.os.linux;

    fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var n: usize = 0;
        while (n < buf.len) {
            const r = linux.read(fd, buf[n..].ptr, buf.len - n);
            switch (linux.errno(r)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return null,
            }
            if (r == 0) break;
            n += r;
        }
        return buf[0..n];
    }

    /// The number after "key:" on its line, times 1024 when it is in kB; null when the key is absent.
    fn field(text: []const u8, key: []const u8) ?u64 {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (l.len <= key.len or l[key.len] != ':' or !std.mem.startsWith(u8, l, key)) continue;
            const rest = std.mem.trim(u8, l[key.len + 1 ..], " \t");
            var end: usize = 0;
            while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
            const v = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
            return if (std.mem.endsWith(u8, rest, "kB")) v * 1024 else v;
        }
        return null;
    }

    const Dir = struct {
        fd: i32,
        buf: [4096]u8 align(8) = undefined,
        pos: usize = 0,
        end: usize = 0,

        fn open(path: [*:0]const u8) ?Dir {
            const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return null;
            return .{ .fd = @intCast(rc) };
        }

        fn close(d: *Dir) void {
            _ = linux.close(d.fd);
        }

        /// The next entry's name, skipping "." and "..".
        fn next(d: *Dir) ?[]const u8 {
            const reclen_at = @offsetOf(linux.dirent64, "reclen");
            const name_at = @offsetOf(linux.dirent64, "name");
            while (true) {
                if (d.pos >= d.end) {
                    const r = linux.getdents64(d.fd, &d.buf, d.buf.len);
                    if (linux.errno(r) != .SUCCESS or r == 0) return null;
                    d.pos = 0;
                    d.end = r;
                }
                const at = d.pos;
                if (d.end - at < name_at) return null;
                const reclen = std.mem.readInt(u16, d.buf[at + reclen_at ..][0..2], builtin.cpu.arch.endian());
                if (reclen <= name_at or reclen > d.end - at) return null;
                d.pos += reclen;
                const name = std.mem.sliceTo(d.buf[at + name_at .. at + reclen], 0);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                return name;
            }
        }
    };

    fn countEntries(path: [*:0]const u8) u32 {
        var d = Dir.open(path) orelse return 0;
        defer d.close();
        var n: u32 = 0;
        while (d.next()) |_| n += 1;
        return n;
    }

    fn sample() ?Sample {
        var status_buf: [8192]u8 = undefined;
        const status = readFile("/proc/self/status", &status_buf) orelse return null;
        var mem_buf: [8192]u8 = undefined;
        const mem = readFile("/proc/meminfo", &mem_buf) orelse return null;
        // The commit figure is RssAnon + VmSwap: the private memory actually backed by RAM or swap. VmData would count
        // every reserved mapping, and each pthread stack reserves 16 MiB it never touches. Kernels before 4.5 have no
        // RssAnon; VmData stands in there.
        const commit = if (field(status, "RssAnon")) |anon| anon + (field(status, "VmSwap") orelse 0) else field(status, "VmData") orelse 0;
        var rd: u64 = 0;
        var wr: u64 = 0;
        var io_buf: [1024]u8 = undefined;
        // /proc/self/io can be unreadable (hardened kernels, some containers): no I/O figures then, not no sample
        if (readFile("/proc/self/io", &io_buf)) |io| {
            rd = field(io, "read_bytes") orelse 0;
            wr = field(io, "write_bytes") orelse 0;
        }
        // CommitLimit is only a limit under strict overcommit (vm.overcommit_memory = 2). Under the default heuristic
        // the real ceiling is RAM + swap, so that is reported instead, and Committed_AS can pass it.
        var oc_buf: [16]u8 = undefined;
        const strict = if (readFile("/proc/sys/vm/overcommit_memory", &oc_buf)) |oc| std.mem.startsWith(u8, oc, "2") else false;
        const limit = if (strict)
            field(mem, "CommitLimit") orelse 0
        else
            (field(mem, "MemTotal") orelse 0) + (field(mem, "SwapTotal") orelse 0);
        const avail = field(mem, "MemAvailable") orelse
            (field(mem, "MemFree") orelse 0) + (field(mem, "Buffers") orelse 0) + (field(mem, "Cached") orelse 0);
        const fds = countEntries("/proc/self/fd");
        return .{
            .t_ms = wallMs(),
            .own_commit = commit,
            .own_ws = field(status, "VmRSS") orelse 0,
            .own_threads = @intCast(@min(field(status, "Threads") orelse 0, std.math.maxInt(u32))),
            .own_handles = fds -| 1, // the listing's own fd
            .own_read = rd,
            .own_write = wr,
            .sys_commit = field(mem, "Committed_AS") orelse 0,
            .sys_limit = limit,
            .sys_avail = avail,
            .defender_read = 0,
            .defender_found = false,
            .limit_enforced = strict,
        };
    }

    fn threadNames(out: *Names) void {
        var d = Dir.open("/proc/self/task") orelse return;
        defer d.close();
        while (d.next()) |tid| {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/proc/self/task/{s}/comm", .{tid}) catch continue;
            var comm_buf: [64]u8 = undefined;
            const comm = readFile(path, &comm_buf) orelse continue; // exited since the listing
            var clean: [Names.name_max]u8 = undefined;
            out.add(printable(std.mem.trimEnd(u8, comm, "\n"), &clean), 1);
        }
    }
};

// ------------------------------------------------------------------------------------------------ tests

const testing = std.testing;

/// A plausible reading the tests bend one field at a time.
fn testSample() Sample {
    return .{
        .t_ms = 1_760_000_000_000,
        .own_commit = 200 * MiB,
        .own_ws = 150 * MiB,
        .own_threads = 40,
        .own_handles = 500,
        .own_read = 10 * MiB,
        .own_write = 1 * MiB,
        .sys_commit = 30 * GiB,
        .sys_limit = 45 * GiB,
        .sys_avail = 6 * GiB,
        .defender_read = 5 * GiB,
        .defender_found = true,
    };
}

test "SYSTEM_PROCESS_INFORMATION and SYSTEM_THREAD_INFORMATION have the x64 offsets" {
    if (comptime @sizeOf(usize) == 8) {
        comptime checkLayout();
    } else return error.SkipZigTest;
}

test "sample reads plausible numbers on this OS" {
    const s = sample(testing.allocator) orelse {
        if (supported) return error.TestUnexpectedResult;
        return error.SkipZigTest;
    };
    try testing.expect(s.own_threads >= 1);
    try testing.expect(s.own_commit > 0);
    try testing.expect(s.own_ws > 0);
    try testing.expect(s.sys_commit > 0);
    try testing.expect(s.sys_limit > 0);
    try testing.expect(s.sys_avail > 0);
    try testing.expect(s.t_ms > 1_700_000_000_000); // after 2023: the epoch conversion is right
    if (builtin.os.tag == .windows) {
        // Windows enforces its commit limit, so the charge can never pass it. Linux under heuristic overcommit can.
        try testing.expect(s.sys_limit >= s.sys_commit);
        try testing.expect(s.own_handles > 0);
        // defender_found is reported either way; Defender may be off on this machine
        if (!s.defender_found) try testing.expectEqual(@as(u64, 0), s.defender_read);
    } else {
        try testing.expect(!s.defender_found);
    }
    // the counters only grow
    const again = sample(testing.allocator).?;
    try testing.expect(again.own_read >= s.own_read);
    try testing.expect(again.own_write >= s.own_write);
}

test "the snapshot's own thread list holds the calling thread (the thread layout is right)" {
    if (!win_supported) return error.SkipZigTest;
    const snap = win.snapshot(testing.allocator) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(snap.buf);
    const own = win.findOwn(&snap) orelse return error.TestUnexpectedResult;
    const me: usize = std.os.windows.GetCurrentThreadId();
    const pid: usize = std.os.windows.GetCurrentProcessId();
    var found = false;
    for (0..own.p.NumberOfThreads) |i| {
        const t = win.threadAt(&snap, own, i) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(pid, t.ClientId.UniqueProcess);
        if (t.ClientId.UniqueThread == me) found = true;
    }
    try testing.expect(found);
}

test "threadNames counts every thread and sees a thread's description" {
    if (!supported) return error.SkipZigTest;
    const T = struct {
        fn run(ready: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            if (builtin.os.tag == .windows) _ = win.SetThreadDescription(win.GetCurrentThread(), std.unicode.utf8ToUtf16LeStringLiteral("veil:vitals-test"));
            ready.store(true, .release);
            while (!done.load(.acquire)) sleepMs(5);
        }
    };
    var ready: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, T.run, .{ &ready, &done }); // a test thread: explicit 1 MiB, not the 16 MiB default commit (check.ps1 2b)
    defer {
        done.store(true, .release);
        t.join();
    }
    while (!ready.load(.acquire)) sleepMs(1);

    var names: Names = .{};
    threadNames(testing.allocator, &names);
    try testing.expect(names.total() >= 2);
    for (names.slice()[1..], 1..) |*e, i| try testing.expect(names.entries[i - 1].count >= e.count); // sorted
    if (builtin.os.tag == .windows) {
        var named: u32 = 0;
        for (names.slice()) |*e| {
            if (std.mem.eql(u8, e.name(), "veil:vitals-test")) named = e.count;
        }
        try testing.expectEqual(@as(u32, 1), named);
    }
}

test "spikes: each rule at its threshold, just under it, and the quiet case" {
    const base = testSample();
    const none: Spike = .{};
    try testing.expectEqual(none, spikes(base, base));

    var c = base;
    c.defender_read += spike_defender_read;
    try testing.expectEqual(Spike{ .defender = true }, spikes(base, c));
    c.defender_read -= 1;
    try testing.expectEqual(none, spikes(base, c));
    c = base;
    c.defender_read += spike_defender_read;
    c.defender_found = false;
    try testing.expectEqual(none, spikes(base, c)); // Defender gone
    var p = base;
    p.defender_found = false;
    try testing.expectEqual(none, spikes(p, c)); // Defender only just appeared
    c = base;
    c.defender_read = 1 * MiB;
    try testing.expectEqual(none, spikes(base, c)); // restarted: its counter went down

    c = base;
    c.own_commit += spike_commit_growth;
    try testing.expectEqual(Spike{ .commit = true }, spikes(base, c));
    c.own_commit -= 1;
    try testing.expectEqual(none, spikes(base, c));
    c.own_commit = 1 * MiB;
    try testing.expectEqual(none, spikes(base, c)); // shrinking is no spike

    c = base;
    c.own_threads += spike_thread_growth;
    try testing.expectEqual(Spike{ .threads = true }, spikes(base, c));
    c.own_threads -= 1;
    try testing.expectEqual(none, spikes(base, c));

    c = base;
    c.sys_avail = low_ram_below - 1;
    try testing.expectEqual(Spike{ .low_ram = true }, spikes(base, c));
    c.sys_avail = low_ram_below;
    try testing.expectEqual(none, spikes(base, c));

    c = base;
    c.sys_limit = 100 * GiB;
    c.sys_commit = 95 * GiB;
    try testing.expectEqual(Spike{ .near_limit = true }, spikes(base, c));
    c.sys_commit = 95 * GiB - 1;
    try testing.expectEqual(none, spikes(base, c));
    c.sys_limit = 0; // limit unknown
    try testing.expectEqual(none, spikes(base, c));

    c = base;
    c.own_commit += spike_commit_growth;
    c.sys_avail = 0;
    const both = spikes(base, c);
    try testing.expect(both.any());
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("spike: commit+low_ram", both.why(&buf));
    try testing.expect(!none.any());
}

test "formatLine: golden line, MB/GB rounding, +N more, and truncation" {
    var prev = testSample();
    prev.own_read = 10 * MiB;
    prev.own_write = 1 * MiB;
    prev.defender_read = 5 * GiB;
    var cur = prev;
    cur.own_commit = 231 * MiB;
    cur.own_ws = 172 * MiB;
    cur.own_threads = 146;
    cur.own_handles = 812;
    cur.own_read = prev.own_read + 2_202_010; // 2.1 MiB
    cur.own_write = prev.own_write + 419_430; // 0.4 MiB
    cur.sys_commit = 39_835_821_261; // 37.1 GiB
    cur.sys_limit = 48_962_627_174; // 45.6 GiB
    cur.sys_avail = 5_905_580_032; // 5.5 GiB
    cur.defender_read = prev.defender_read + 1_288_490_189; // 1.2 GiB

    var names: Names = .{};
    names.add("veil:http", 128);
    names.add("veil:chat-turn", 1);
    names.add(unnamed, 9);
    for ([_][]const u8{ "veil:sched", "veil:vitals", "veil:watch", "veil:desk", "veil:cast", "veil:sentry" }) |n| names.add(n, 1);
    names.add("veil:llm", 2);
    names.sort();

    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "vitals[60s]: veil commit 231 MB, ws 172 MB, threads 146 (veil:http 128, (unnamed) 9, veil:llm 2, veil:cast 1, " ++
            "veil:chat-turn 1, veil:desk 1, veil:sched 1, veil:sentry 1, +2 more), handles 812, io r 2.1 MB w 0.4 MB " ++
            "| system commit 37.1/45.6 GB, 5.5 GB free | defender read 1.2 GB",
        formatLine(&buf, prev, cur, &names, "60s"),
    );

    // no prev: no deltas; no names: no breakdown
    var start = cur;
    start.own_commit = 1536 * MiB;
    start.own_ws = 1000 * MiB; // the first GB reading
    start.sys_commit = 700 * MiB;
    start.sys_limit = 999 * MiB;
    start.sys_avail = 0;
    try testing.expectEqualStrings(
        "vitals[start]: veil commit 1.5 GB, ws 1.0 GB, threads 146, handles 812 | system commit 700/999 MB, 0.0 MB free",
        formatLine(&buf, null, start, null, "start"),
    );

    // rounding at the unit edges: 99.96 MiB rounds up into whole units, 99.94 stays at one decimal
    var w: std.Io.Writer = .fixed(&buf);
    try writeSize(&w, 104_815_575); // 99.96 MiB
    try w.writeByte(',');
    try writeSize(&w, 104_794_604); // 99.94 MiB
    try w.writeByte(',');
    try writeSize(&w, 52_429); // 0.05 MiB, half up
    try w.writeByte(',');
    try writeSize(&w, 145 * GiB + GiB / 2);
    try testing.expectEqualStrings("100 MB,99.9 MB,0.1 MB,146 GB", w.buffered());

    // only overflowed names still say how many
    const over: Names = .{ .overflow = 3 };
    try testing.expect(std.mem.indexOf(u8, formatLine(&buf, null, cur, &over, "x"), "threads 146 (+3 more)") != null);

    // a tiny buffer is filled and cut, never overrun
    var tiny: [8]u8 = undefined;
    try testing.expectEqualStrings("vitals[6", formatLine(&tiny, prev, cur, &names, "60s"));
    try testing.expectEqualStrings("", formatLine(tiny[0..0], prev, cur, &names, "60s"));
}

test "the ring keeps the newest 120 samples, oldest first" {
    var ctx: Ctx = .{ .gpa = testing.allocator };
    var out: [ring_cap]Sample = undefined;
    try testing.expectEqual(@as(usize, 0), ctx.recent(&out).len);
    var s = testSample();
    for (0..130) |i| {
        s.t_ms = @intCast(i);
        ctx.push(s);
    }
    const kept = ctx.recent(&out);
    try testing.expectEqual(@as(usize, ring_cap), kept.len);
    try testing.expectEqual(@as(i64, 10), kept[0].t_ms);
    try testing.expectEqual(@as(i64, 129), kept[kept.len - 1].t_ms);
    for (kept[1..], 1..) |k, i| try testing.expectEqual(kept[i - 1].t_ms + 1, k.t_ms);
}

test "renderJson parses back with samples and threads" {
    var ctx: Ctx = .{ .gpa = testing.allocator };
    var s = testSample();
    for (0..3) |i| {
        s.t_ms += @intCast(i);
        s.defender_found = i != 1;
        ctx.push(s);
    }
    const out = try renderJson(&ctx, testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const samples = root.get("samples").?.array.items;
    try testing.expectEqual(@as(usize, 3), samples.len);
    try testing.expectEqual(@as(i64, 30 * GiB), samples[0].object.get("sys_commit").?.integer);
    try testing.expectEqual(false, samples[1].object.get("defender_found").?.bool);
    try testing.expectEqual(true, samples[2].object.get("defender_found").?.bool);
    const threads = root.get("threads").?.object;
    if (supported) try testing.expect(threads.count() >= 1);
    try testing.expectEqual(@as(i64, 60), root.get("log_every_s").?.integer);

    // names are cut down to bytes that need no escaping, and names that clean alike merge
    var names: Names = .{ .overflow = 2 };
    names.add("a\"b\\c", 1);
    names.add("a?b?c", 2);
    names.add("veil:http (x+y) 1.2_3-4", 5);
    names.add("t\xc3\xa9\n", 1);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, &.{}, &names, 60_000, 5000);
    try testing.expectEqualStrings(
        "{\"samples\":[],\"threads\":{\"a?b?c\":3,\"veil:http (x+y) 1.2_3-4\":5,\"t???\":1,\"(other)\":2}," ++
            "\"log_every_s\":60,\"sample_every_ms\":5000}",
        aw.written(),
    );
    const again = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer again.deinit();
}

test "renderJson: a thread named \"(other)\" shares the overflow's key, never repeats it" {
    // with overflow: one "(other)" key holding both counts, and std.json (which refuses a repeated key) parses it
    var names: Names = .{ .overflow = 4 };
    names.add("veil:http", 3);
    names.add(other_key, 2);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, &.{}, &names, 60_000, 5000);
    try testing.expectEqualStrings(
        "{\"samples\":[],\"threads\":{\"veil:http\":3,\"(other)\":6},\"log_every_s\":60,\"sample_every_ms\":5000}",
        aw.written(),
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const threads = parsed.value.object.get("threads").?.object;
    try testing.expectEqual(@as(usize, 2), threads.count());
    try testing.expectEqual(@as(i64, 6), threads.get(other_key).?.integer);

    // the name alone, no overflow: still one key, and no stray comma before it
    var alone: Names = .{};
    alone.add(other_key, 2);
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try writeJson(&aw2.writer, &.{}, &alone, 60_000, 5000);
    try testing.expectEqualStrings(
        "{\"samples\":[],\"threads\":{\"(other)\":2},\"log_every_s\":60,\"sample_every_ms\":5000}",
        aw2.written(),
    );
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw2.written(), .{});
    defer parsed2.deinit();

    // a full table of names plus "(other)" plus overflow: every key once
    var full: Names = .{ .overflow = 1 };
    var nb: [16]u8 = undefined;
    for (0..Names.max - 1) |i| full.add(std.fmt.bufPrint(&nb, "veil:t{d}", .{i}) catch unreachable, 1);
    full.add(other_key, 5);
    full.add("veil:late", 7); // no slot left: overflow
    var aw3: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw3.deinit();
    try writeJson(&aw3.writer, &.{}, &full, 60_000, 5000);
    const parsed3 = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw3.written(), .{});
    defer parsed3.deinit();
    const t3 = parsed3.value.object.get("threads").?.object;
    try testing.expectEqual(@as(usize, Names.max), t3.count()); // 31 names + "(other)"
    try testing.expectEqual(@as(i64, 1 + 5 + 7), t3.get(other_key).?.integer);
}

test "the window line and renderJson report the span the window really covers" {
    // whole samples: exact
    try testing.expectEqual(@as(u64, 60_000), windowMs(60, 5000));
    try testing.expectEqual(@as(u64, 5_000), windowMs(5, 5000));
    try testing.expectEqual(@as(u64, 3_600_000), windowMs(3600, 5000));
    // not a whole number of samples: rounded to the nearest, so the label says 10 s, not 8 or 12
    try testing.expectEqual(@as(u64, 10_000), windowMs(8, 5000));
    try testing.expectEqual(@as(u64, 10_000), windowMs(12, 5000));
    try testing.expectEqual(@as(u64, 15_000), windowMs(13, 5000));
    // at least one sample; a period under 100 ms runs at 100
    try testing.expectEqual(@as(u64, 10_000), windowMs(5, 10_000));
    try testing.expectEqual(@as(u64, 60_000), windowMs(60, 50));
    try testing.expectEqual(@as(u64, 7_500), windowMs(7, 1500));

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("60s", windowLabel(&buf, windowMs(60, 5000)));
    try testing.expectEqualStrings("10s", windowLabel(&buf, windowMs(8, 5000)));
    try testing.expectEqualStrings("7.5s", windowLabel(&buf, windowMs(7, 1500)));
    try testing.expectEqualStrings("0.25s", windowLabel(&buf, 250));
    try testing.expectEqualStrings("1.005s", windowLabel(&buf, 1005));
    try testing.expectEqualStrings("0.1s", windowLabel(&buf, 100));
    try testing.expectEqualStrings("18446744073709551.615s", windowLabel(&buf, std.math.maxInt(u64)));
    var tiny: [2]u8 = undefined;
    try testing.expectEqualStrings("window", windowLabel(&tiny, 60_000));

    // renderJson says what loop() runs on: NL_VITALS_LOG_S=8 is a 10 s window, a 50 ms period is 100 ms
    var ctx: Ctx = .{ .gpa = testing.allocator, .log_every_s = 8 };
    const out = try renderJson(&ctx, testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 10), parsed.value.object.get("log_every_s").?.integer);
    try testing.expectEqual(@as(i64, 5000), parsed.value.object.get("sample_every_ms").?.integer);

    var odd: Ctx = .{ .gpa = testing.allocator, .log_every_s = 7, .sample_every_ms = 1500 };
    const out2 = try renderJson(&odd, testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.endsWith(u8, out2, ",\"log_every_s\":7.5,\"sample_every_ms\":1500}"));
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, out2, .{});
    defer parsed2.deinit();
    try testing.expectEqual(@as(f64, 7.5), parsed2.value.object.get("log_every_s").?.float);

    var fast: Ctx = .{ .gpa = testing.allocator, .sample_every_ms = 50 };
    const out3 = try renderJson(&fast, testing.allocator);
    defer testing.allocator.free(out3);
    try testing.expect(std.mem.endsWith(u8, out3, ",\"log_every_s\":60,\"sample_every_ms\":100}"));
}

test "enabled and logEvery read their env values" {
    try testing.expect(enabled(null));
    try testing.expect(enabled(""));
    try testing.expect(enabled("1"));
    try testing.expect(enabled("on"));
    try testing.expect(enabled("yes"));
    try testing.expect(!enabled("0"));
    try testing.expect(!enabled("off"));
    try testing.expect(!enabled("OFF"));
    try testing.expect(!enabled("False"));
    try testing.expect(!enabled(" false\n"));

    try testing.expectEqual(@as(u32, 60), logEvery(null));
    try testing.expectEqual(@as(u32, 60), logEvery(""));
    try testing.expectEqual(@as(u32, 60), logEvery("soon"));
    try testing.expectEqual(@as(u32, 60), logEvery("-5"));
    try testing.expectEqual(@as(u32, 30), logEvery("30"));
    try testing.expectEqual(@as(u32, 30), logEvery(" 30 "));
    try testing.expectEqual(@as(u32, 5), logEvery("0"));
    try testing.expectEqual(@as(u32, 5), logEvery("4"));
    try testing.expectEqual(@as(u32, 3600), logEvery("3601"));
    try testing.expectEqual(@as(u32, 3600), logEvery("99999999999999999999999"));
}

test "loop samples into the ring and stops when asked" {
    var ctx: Ctx = .{ .gpa = testing.allocator, .sample_every_ms = 100 };
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, loop, .{&ctx}); // a test thread: explicit 1 MiB (check.ps1 2b)
    var out: [ring_cap]Sample = undefined;
    var waited: u32 = 0;
    while (supported and waited < 5000 and ctx.recent(&out).len < 2) : (waited += 10) sleepMs(10);
    ctx.stop.store(true, .release);
    t.join();
    const kept = ctx.recent(&out);
    if (supported) {
        try testing.expect(kept.len >= 2);
        try testing.expect(kept[1].t_ms >= kept[0].t_ms);
    } else {
        try testing.expectEqual(@as(usize, 0), kept.len);
    }
}

test "near_limit warns only about a limit the OS enforces" {
    var a: Sample = std.mem.zeroes(Sample);
    a.sys_avail = 8 * GiB;
    a.sys_limit = 10 * GiB;
    a.sys_commit = 12 * GiB; // past the figure, as Committed_AS can be under heuristic overcommit
    a.limit_enforced = true;
    try std.testing.expect(spikes(a, a).near_limit);
    a.limit_enforced = false; // Linux, vm.overcommit_memory 0 or 1: nothing is refused at this figure
    try std.testing.expect(!spikes(a, a).near_limit);
    try std.testing.expect(!spikes(a, a).any());
}
