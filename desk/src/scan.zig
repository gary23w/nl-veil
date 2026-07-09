//! scan.zig — the filesystem data layer. veil-desk is a same-machine companion to the veil server, so
//! reads go straight to the run directories under <home>/data (no HTTP, no auth, no latency) exactly as
//! the engine writes them: each swarm is a subdir with events.jsonl (the event stream), .goal_brief,
//! .blueprint, control.jsonl (the operator bus). Everything here runs on the POLLER thread only and
//! publishes into the mutex-guarded Store; the UI thread never touches io.

const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");

pub const MAX_LOG = 400; // ring of the most-recent event lines held for the log console
pub const MAX_SWARMS = 64;
pub const MAX_FILES = 64; // built files listed in the Files tab

/// One file a swarm has built, for the Files tab. Path is relative to the swarm's work/ dir.
pub const FileRow = struct {
    path: [128]u8 = [_]u8{0} ** 128,
    path_len: u8 = 0,
    size: u64 = 0,
    pub fn pathStr(f: *const FileRow) []const u8 {
        return f.path[0..f.path_len];
    }
};

/// One parsed line of a swarm's events.jsonl, reduced to what the console + metrics need.
pub const Ev = struct {
    seq: u64 = 0,
    round: i64 = -1,
    kind: [24]u8 = [_]u8{0} ** 24,
    kind_len: u8 = 0,
    mind: [24]u8 = [_]u8{0} ** 24,
    mind_len: u8 = 0,
    text: [220]u8 = [_]u8{0} ** 220, // a human line: tool+result, or monologue, or the score summary
    text_len: u16 = 0,

    pub fn kindStr(e: *const Ev) []const u8 {
        return e.kind[0..e.kind_len];
    }
    pub fn mindStr(e: *const Ev) []const u8 {
        return e.mind[0..e.mind_len];
    }
    pub fn textStr(e: *const Ev) []const u8 {
        return e.text[0..e.text_len];
    }
};

/// Running metrics distilled from the whole stream — the numbers the metrics panel shows.
pub const Metrics = struct {
    round: i64 = 0,
    pct: i32 = -1,
    passed: i32 = 0,
    total: i32 = 0,
    best_pct: i32 = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    tokens_cached: u64 = 0,
    calls: u64 = 0,
    files: i32 = 0,
    minds: i32 = 0,
    smoke_ok: bool = false,
    smoke_seen: bool = false,
    stopped: bool = false,
    stop_reason: [40]u8 = [_]u8{0} ** 40,
    stop_reason_len: u8 = 0,
    gradient_warn: bool = false, // the zero-gradient sentinel fired at least once
};

pub const SwarmSummary = struct {
    id: [96]u8 = [_]u8{0} ** 96, // path RELATIVE to data dir: "name" (CLI run) or "u1/<hexid>" (server deploy)
    id_len: u8 = 0,
    name: [64]u8 = [_]u8{0} ** 64, // friendly display name (swarm.json "swarm", else the dir basename)
    name_len: u8 = 0,
    round: i64 = 0,
    pct: i32 = -1,
    live: bool = false, // events.jsonl touched recently AND no terminal 'stopped'
    stopped: bool = false,
    mtime_s: i64 = 0,
    goal: [160]u8 = [_]u8{0} ** 160,
    goal_len: u8 = 0,

    pub fn idStr(s: *const SwarmSummary) []const u8 {
        return s.id[0..s.id_len];
    }
    pub fn nameStr(s: *const SwarmSummary) []const u8 {
        return if (s.name_len > 0) s.name[0..s.name_len] else s.id[0..s.id_len];
    }
    pub fn goalStr(s: *const SwarmSummary) []const u8 {
        return s.goal[0..s.goal_len];
    }
};

fn setBuf(dst: []u8, len: *u8, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = @intCast(n);
}
fn setBuf16(dst: []u8, len: *u16, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = @intCast(n);
}

/// A tiny JSON string-field reader — the events are flat objects, so a scan for "key":"..." / "key":N is
/// enough and far cheaper than a full parse per line at 60fps-adjacent poll rates. Not a general parser.
fn jsonStr(line: []const u8, key: []const u8, out: *[256]u8) ?[]const u8 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = at + needle.len;
    while (i < line.len and (line[i] == ' ')) i += 1;
    if (i >= line.len or line[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < line.len and w < out.len) : (i += 1) {
        const c = line[i];
        if (c == '\\') {
            i += 1;
            if (i >= line.len) break;
            const e = line[i];
            out[w] = switch (e) {
                'n' => '\n',
                't' => ' ',
                'r' => '\r',
                'u' => blk: {
                    i += 4; // skip the 4 hex digits; render the escape as a space (console is ASCII-ish)
                    break :blk ' ';
                },
                else => e,
            };
            w += 1;
            continue;
        }
        if (c == '"') break;
        out[w] = c;
        w += 1;
    }
    return out[0..w];
}

fn jsonInt(line: []const u8, key: []const u8) ?i64 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = at + needle.len;
    while (i < line.len and line[i] == ' ') i += 1;
    var neg = false;
    if (i < line.len and line[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        v = v * 10 + (line[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -v else v;
}

/// Read the last `want` newline-delimited records of a (possibly large, actively-written) events.jsonl by
/// tailing only the final window of the file — the console never needs the whole history, and a swarm's
/// stream grows to megabytes. Returns the number of Ev written into `out`, oldest-first.
pub fn tailEvents(io: Io, gpa: std.mem.Allocator, path: []const u8, out: []Ev, metrics: *Metrics) usize {
    return tailEventsFrom(io, gpa, path, 0, out, metrics);
}

/// tailEvents that folds only bytes past `from` — a cast records the file size when it detects a STALE
/// prior run's events in a reused dir, so the old run's "stopped"/score lines can never complete the new
/// cast. Reads a bounded window (never the whole multi-MB file — this used to be an 8MB read + full
/// two-pass parse EVERY SECOND on the chat thread, a real slice of the local cast thrash).
const TAIL_WINDOW: u64 = 256 << 10;
pub fn tailEventsFrom(io: Io, gpa: std.mem.Allocator, path: []const u8, from: u64, out: []Ev, metrics: *Metrics) usize {
    log.trace("scan.tailEvents path={s} from={d}", .{ path, from });
    metrics.* = .{};
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    const size: u64 = st.size;
    if (size <= from) return 0;
    var start = from;
    var torn = false; // did the window cut land mid-line?
    if (size - start > TAIL_WINDOW) {
        start = size - TAIL_WINDOW;
        torn = true;
    }
    const want: usize = @intCast(size - start);
    const buf = gpa.alloc(u8, want) catch return 0;
    defer gpa.free(buf);
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    const rn = f.readPositionalAll(io, buf, start) catch return 0;
    var data: []const u8 = buf[0..rn];
    if (torn) {
        // skip the torn first record; `from` itself always lands on a line start (whole lines are appended)
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return 0;
        data = data[nl + 1 ..];
    }
    // First pass over the window: accumulate cumulative metrics (tokens, best, stop) — cost totals are
    // cumulative per line, so the newest line in the window carries the run's true totals.
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len < 8) continue;
        foldMetrics(line, metrics);
    }
    // Second pass: keep only the last `out.len` human-meaningful lines for the console ring.
    var ring_lo: usize = 0;
    var count: usize = 0;
    var it2 = std.mem.splitScalar(u8, data, '\n');
    while (it2.next()) |line| {
        if (line.len < 8) continue;
        var ev: Ev = .{};
        if (!parseEv(line, &ev)) continue;
        out[(ring_lo + count) % out.len] = ev;
        if (count < out.len) count += 1 else ring_lo = (ring_lo + 1) % out.len;
    }
    // Compact the ring into out[0..count] oldest-first for the caller.
    if (count == out.len and ring_lo != 0) {
        var tmp = gpa.alloc(Ev, count) catch return count;
        defer gpa.free(tmp);
        var i: usize = 0;
        while (i < count) : (i += 1) tmp[i] = out[(ring_lo + i) % out.len];
        @memcpy(out[0..count], tmp[0..count]);
    }
    return count;
}

fn foldMetrics(line: []const u8, m: *Metrics) void {
    var kb: [256]u8 = undefined;
    const kind = jsonStr(line, "kind", &kb) orelse return;
    if (std.mem.eql(u8, kind, "score")) {
        if (jsonInt(line, "round")) |r| m.round = r;
        if (jsonInt(line, "pct")) |p| {
            m.pct = @intCast(p);
            if (p > m.best_pct) m.best_pct = @intCast(p);
        }
        if (jsonInt(line, "passed")) |p| m.passed = @intCast(p);
        if (jsonInt(line, "total")) |t| m.total = @intCast(t);
    } else if (std.mem.eql(u8, kind, "phase")) {
        // RESEARCH/discourse casts never emit a "score" (no benchmark) — their per-round progress is a
        // "phase" event carrying now/best. Reading it here is what makes the hive-running label move instead
        // of sitting at 0% for the whole cast (the reported bug).
        if (jsonInt(line, "round")) |r| m.round = r;
        if (jsonInt(line, "now")) |p| {
            m.pct = @intCast(p);
            if (p > m.best_pct) m.best_pct = @intCast(p);
        }
        if (jsonInt(line, "best")) |b| {
            if (b > m.best_pct) m.best_pct = @intCast(b);
        }
    } else if (std.mem.eql(u8, kind, "cost")) {
        if (jsonInt(line, "total_in")) |v| m.tokens_in = @intCast(v);
        if (jsonInt(line, "total_out")) |v| m.tokens_out = @intCast(v);
        if (jsonInt(line, "total_cached")) |v| m.tokens_cached = @intCast(v);
        if (jsonInt(line, "calls")) |v| m.calls += @intCast(v);
    } else if (std.mem.eql(u8, kind, "files")) {
        if (jsonInt(line, "n")) |v| m.files = @intCast(v);
    } else if (std.mem.eql(u8, kind, "board")) {
        if (jsonInt(line, "files")) |v| m.minds = @intCast(v);
    } else if (std.mem.eql(u8, kind, "stopped")) {
        m.stopped = true;
        var rb: [256]u8 = undefined;
        if (jsonStr(line, "reason", &rb)) |rs| setBuf(&m.stop_reason, &m.stop_reason_len, rs);
    } else if (std.mem.eql(u8, kind, "act")) {
        var tb: [256]u8 = undefined;
        const tool = jsonStr(line, "tool", &tb) orelse return;
        if (std.mem.eql(u8, tool, "smoke")) {
            m.smoke_seen = true;
            var ab: [256]u8 = undefined;
            const args = jsonStr(line, "args", &ab) orelse "";
            m.smoke_ok = std.mem.indexOf(u8, args, "ok") != null;
        } else if (std.mem.eql(u8, tool, "gradient")) {
            m.gradient_warn = true;
        }
    }
}

/// Turn one JSONL line into a console Ev. Returns false for pure-noise records we don't surface.
fn parseEv(line: []const u8, ev: *Ev) bool {
    var kb: [256]u8 = undefined;
    const kind = jsonStr(line, "kind", &kb) orelse return false;
    setBuf(&ev.kind, &ev.kind_len, kind);
    if (jsonInt(line, "seq")) |s| ev.seq = @intCast(s);
    if (jsonInt(line, "round")) |r| ev.round = r;
    var mb: [256]u8 = undefined;
    if (jsonStr(line, "mind", &mb)) |mn| setBuf(&ev.mind, &ev.mind_len, mn);

    // Compose a readable line per event kind so the console reads like a narrated log, not raw JSON.
    if (std.mem.eql(u8, kind, "act")) {
        var tb: [256]u8 = undefined;
        var rb: [256]u8 = undefined;
        const tool = jsonStr(line, "tool", &tb) orelse "";
        const res = jsonStr(line, "result", &rb) orelse "";
        composeText(ev, tool, res);
    } else if (std.mem.eql(u8, kind, "tick")) {
        var rb: [256]u8 = undefined;
        const mono = jsonStr(line, "monologue", &rb) orelse "";
        composeText(ev, "think", mono);
    } else if (std.mem.eql(u8, kind, "score")) {
        var buf: [220]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "score {d}/{d} ({d}%)", .{ jsonInt(line, "passed") orelse 0, jsonInt(line, "total") orelse 0, jsonInt(line, "pct") orelse 0 }) catch "score";
        setBuf16(&ev.text, &ev.text_len, s);
    } else if (std.mem.eql(u8, kind, "cost")) {
        var buf: [220]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "cost +{d} in / +{d} out ({d} calls)", .{ jsonInt(line, "in") orelse 0, jsonInt(line, "out") orelse 0, jsonInt(line, "calls") orelse 0 }) catch "cost";
        setBuf16(&ev.text, &ev.text_len, s);
    } else if (std.mem.eql(u8, kind, "goal") or std.mem.eql(u8, kind, "complete") or std.mem.eql(u8, kind, "stopped") or std.mem.eql(u8, kind, "board") or std.mem.eql(u8, kind, "files") or std.mem.eql(u8, kind, "growth")) {
        var rb: [256]u8 = undefined;
        const g = jsonStr(line, "goal", &rb) orelse (jsonStr(line, "reason", &rb) orelse "");
        setBuf16(&ev.text, &ev.text_len, g);
    } else {
        return false; // psyche/flare/etc — not surfaced in the base console
    }
    return true;
}

fn composeText(ev: *Ev, a: []const u8, b: []const u8) void {
    var buf: [220]u8 = undefined;
    const s = if (b.len > 0) std.fmt.bufPrint(&buf, "{s}: {s}", .{ a, b }) catch a else a;
    setBuf16(&ev.text, &ev.text_len, s);
}

/// Enumerate swarm run dirs under `data_dir`. A swarm is any dir with an events.jsonl — and crucially the
/// server writes deploys ONE LEVEL DOWN under per-user accounts (data/u<uid>/<hexid>/), while the CLI
/// writes flat (data/<name>/). So: if data/X has events.jsonl it's a swarm; otherwise if X is a plain
/// container dir, descend one level and take each data/X/child that has events.jsonl. The stored `id` is
/// the path RELATIVE to data_dir (so control/tail resolve correctly for both layouts); `name` is friendly.
pub fn listSwarms(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, out: []SwarmSummary, now_s: i64, live_window_s: i64) usize {
    log.trace("scan.listSwarms data_dir={s}", .{data_dir});
    var dir = Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (n < out.len) {
        const entry = (it.next(io) catch break) orelse break;
        if (entry.kind != .directory) continue;
        const name = entry.name;
        if (name.len == 0 or name[0] == '.' or name[0] == '_') continue; // skip dot/underscore sidecars
        if (addSwarm(io, gpa, data_dir, name, out, &n, now_s, live_window_s)) continue;
        // no events.jsonl here → treat as a container (e.g. u<uid>/) and descend exactly one level.
        var nbuf: [512]u8 = undefined;
        const sub = std.fmt.bufPrint(&nbuf, "{s}/{s}", .{ data_dir, name }) catch continue;
        var sd = Io.Dir.cwd().openDir(io, sub, .{ .iterate = true }) catch continue;
        defer sd.close(io);
        var sit = sd.iterate();
        while (n < out.len) {
            const ce = (sit.next(io) catch break) orelse break;
            if (ce.kind != .directory or ce.name.len == 0 or ce.name[0] == '.') continue;
            var rbuf: [96]u8 = undefined;
            const rel = std.fmt.bufPrint(&rbuf, "{s}/{s}", .{ name, ce.name }) catch continue;
            if (addSwarm(io, gpa, data_dir, rel, out, &n, now_s, live_window_s)) continue;
            // A chat CAST builds in u<uid>/_chat/builds/<conv> (the v27 build-in-place change), which is one level
            // deeper than a normal u<uid>/<hex> swarm — descend into _chat/builds/* so the chat can watch + collect
            // its own casts (else it never sees the run dir and hangs on "watching").
            if (std.mem.eql(u8, ce.name, "_chat")) {
                var bbuf: [512]u8 = undefined;
                const builds = std.fmt.bufPrint(&bbuf, "{s}/{s}/_chat/builds", .{ data_dir, name }) catch continue;
                var bd = Io.Dir.cwd().openDir(io, builds, .{ .iterate = true }) catch continue;
                defer bd.close(io);
                var bit = bd.iterate();
                while (n < out.len) {
                    const be = (bit.next(io) catch break) orelse break;
                    if (be.kind != .directory or be.name.len == 0 or be.name[0] == '.') continue;
                    var r2: [96]u8 = undefined;
                    const rel2 = std.fmt.bufPrint(&r2, "{s}/_chat/builds/{s}", .{ name, be.name }) catch continue;
                    _ = addSwarm(io, gpa, data_dir, rel2, out, &n, now_s, live_window_s);
                }
            }
        }
    }
    // newest activity first
    std.mem.sort(SwarmSummary, out[0..n], {}, struct {
        fn lt(_: void, a: SwarmSummary, b: SwarmSummary) bool {
            return a.mtime_s > b.mtime_s;
        }
    }.lt);
    return n;
}

/// If data_dir/rel has an events.jsonl, append a summary for it and return true; else false.
fn addSwarm(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, rel: []const u8, out: []SwarmSummary, n: *usize, now_s: i64, live_window_s: i64) bool {
    const ev_path = std.fmt.allocPrint(gpa, "{s}/{s}/events.jsonl", .{ data_dir, rel }) catch return false;
    defer gpa.free(ev_path);
    const st = Io.Dir.cwd().statFile(io, ev_path, .{}) catch return false;
    var s: SwarmSummary = .{};
    setBuf(&s.id, &s.id_len, rel);
    // friendly name: swarm.json "swarm", else the last path segment.
    readSwarmName(io, gpa, data_dir, rel, &s);
    if (s.name_len == 0) {
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |sl| rel[sl + 1 ..] else rel;
        setBuf(&s.name, &s.name_len, base);
    }
    s.mtime_s = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    summarizeTail(io, gpa, ev_path, &s);
    s.live = !s.stopped and (now_s - s.mtime_s) <= live_window_s;
    readGoalBrief(io, gpa, data_dir, rel, &s);
    out[n.*] = s;
    n.* += 1;
    return true;
}

fn readSwarmName(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, rel: []const u8, s: *SwarmSummary) void {
    const p = std.fmt.allocPrint(gpa, "{s}/{s}/swarm.json", .{ data_dir, rel }) catch return;
    defer gpa.free(p);
    const data = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(8 << 10)) catch return;
    defer gpa.free(data);
    var nb: [256]u8 = undefined;
    if (jsonStr(data, "swarm", &nb)) |nm| setBuf(&s.name, &s.name_len, nm);
}

/// Roster summary: the latest score + stopped marker. Reads only the LAST 64KB of events.jsonl — the
/// latest score and any "stopped" sit at the end, and this runs for EVERY run dir on disk every second
/// (the old whole-file read, up to 16MB per dir per tick, was the poller's slice of the local thrash).
fn summarizeTail(io: Io, gpa: std.mem.Allocator, ev_path: []const u8, s: *SwarmSummary) void {
    const CAP: u64 = 64 << 10;
    const st = Io.Dir.cwd().statFile(io, ev_path, .{}) catch return;
    const size: u64 = st.size;
    if (size == 0) return;
    const start = if (size > CAP) size - CAP else 0;
    const want: usize = @intCast(size - start);
    const buf = gpa.alloc(u8, want) catch return;
    defer gpa.free(buf);
    const f = Io.Dir.cwd().openFile(io, ev_path, .{}) catch return;
    defer f.close(io);
    const rn = f.readPositionalAll(io, buf, start) catch return;
    var data: []const u8 = buf[0..rn];
    if (start > 0) {
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return;
        data = data[nl + 1 ..];
    }
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len < 8) continue;
        var kb: [256]u8 = undefined;
        const kind = jsonStr(line, "kind", &kb) orelse continue;
        if (std.mem.eql(u8, kind, "score")) {
            if (jsonInt(line, "round")) |r| s.round = r;
            if (jsonInt(line, "pct")) |p| s.pct = @intCast(p);
        } else if (std.mem.eql(u8, kind, "stopped")) {
            s.stopped = true;
        }
    }
}

fn readGoalBrief(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, name: []const u8, s: *SwarmSummary) void {
    const gb = std.fmt.allocPrint(gpa, "{s}/{s}/.goal_brief", .{ data_dir, name }) catch return;
    defer gpa.free(gb);
    const data = Io.Dir.cwd().readFileAlloc(io, gb, gpa, .limited(4 << 10)) catch return;
    defer gpa.free(data);
    const t = std.mem.trim(u8, data, " \r\n\t");
    setBuf(&s.goal, &s.goal_len, t);
}

/// List the files a swarm has built — the Files tab's data. Reads <data>/<rel>/.build_manifest, whose
/// lines are "path|bytes|valve" (the same file the server's swarmFiles handler reads); de-dups repeated
/// paths keeping the latest size. Falls back to walking work/ (one level) when there's no manifest yet
/// (early in a run). `rel` is the swarm path relative to data_dir. Returns count written into `out`.
pub fn listWorkFiles(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, rel: []const u8, out: []FileRow) usize {
    log.trace("scan.listWorkFiles rel={s}", .{rel});
    var n: usize = 0;
    const mp = std.fmt.allocPrint(gpa, "{s}/{s}/.build_manifest", .{ data_dir, rel }) catch return 0;
    defer gpa.free(mp);
    if (Io.Dir.cwd().readFileAlloc(io, mp, gpa, .limited(256 << 10))) |data| {
        defer gpa.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            if (n >= out.len) break;
            const ln = std.mem.trim(u8, raw, " \r\t");
            if (ln.len == 0) continue;
            const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
            const path = ln[0..bar];
            if (path.len == 0) continue;
            const rest = ln[bar + 1 ..];
            const bar2 = std.mem.indexOfScalar(u8, rest, '|') orelse rest.len;
            const size = std.fmt.parseInt(u64, std.mem.trim(u8, rest[0..bar2], " \r\t"), 10) catch 0;
            var found = false;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                if (std.mem.eql(u8, out[k].path[0..out[k].path_len], path)) {
                    out[k].size = size;
                    found = true;
                    break;
                }
            }
            if (found) continue;
            var f: FileRow = .{ .size = size };
            const pn = @min(path.len, f.path.len);
            @memcpy(f.path[0..pn], path[0..pn]);
            f.path_len = @intCast(pn);
            out[n] = f;
            n += 1;
        }
    } else |_| {}
    // UNION with a recursive filesystem walk: the manifest only records files written through write_file, and
    // only flat — but a hive can produce oddly-named or NESTED files (research/RESEARCH_AMERICAS.md) or files
    // created some other way. Walk work/ so collect sees EVERYTHING actually on disk, not just manifest rows.
    const wp = std.fmt.allocPrint(gpa, "{s}/{s}/work", .{ data_dir, rel }) catch return n;
    defer gpa.free(wp);
    walkWork(io, gpa, wp, "", out, &n, 0);
    return n;
}

/// Recursively add every file under `work_root`/`prefix` (work-relative sub-path, '/'-joined) into `out`,
/// skipping dotfiles / __pycache__ / *.pyc and files already present (from the manifest). Bounded depth so a
/// pathological tree can't spin. Missing dir -> no-op. Sizes come from statFile.
fn walkWork(io: Io, gpa: std.mem.Allocator, work_root: []const u8, prefix: []const u8, out: []FileRow, n: *usize, depth: u8) void {
    if (n.* >= out.len or depth > 4) return;
    const dpath = if (prefix.len == 0)
        gpa.dupe(u8, work_root) catch return
    else
        std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_root, prefix }) catch return;
    defer gpa.free(dpath);
    var d = Io.Dir.cwd().openDir(io, dpath, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (n.* < out.len) {
        const e = (it.next(io) catch break) orelse break;
        if (e.name.len == 0 or e.name[0] == '.') continue; // dotfiles, ., ..
        var subbuf: [200]u8 = undefined;
        const sub = (if (prefix.len == 0)
            std.fmt.bufPrint(&subbuf, "{s}", .{e.name})
        else
            std.fmt.bufPrint(&subbuf, "{s}/{s}", .{ prefix, e.name })) catch continue;
        if (e.kind == .directory) {
            if (std.mem.eql(u8, e.name, "__pycache__")) continue;
            walkWork(io, gpa, work_root, sub, out, n, depth + 1);
            continue;
        }
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".pyc")) continue;
        var dup = false;
        var k: usize = 0;
        while (k < n.*) : (k += 1) {
            if (std.mem.eql(u8, out[k].path[0..out[k].path_len], sub)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        var f: FileRow = .{};
        const pn = @min(sub.len, f.path.len);
        @memcpy(f.path[0..pn], sub[0..pn]);
        f.path_len = @intCast(pn);
        const fpath = std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_root, sub }) catch "";
        defer if (fpath.len > 0) gpa.free(fpath);
        if (fpath.len > 0) {
            if (Io.Dir.cwd().statFile(io, fpath, .{})) |st| {
                f.size = st.size;
            } else |_| {}
        }
        out[n.*] = f;
        n.* += 1;
    }
}

/// Read a built file's content for the Files viewer, from <data>/<rel>/work/<sub>. Copies up to out.len
/// bytes; sets trunc if the file was larger. Rejects absolute/escape paths. Returns bytes copied.
pub fn readWorkFile(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, rel: []const u8, sub: []const u8, out: []u8, trunc: *bool) usize {
    log.trace("scan.readWorkFile rel={s} sub={s}", .{ rel, sub });
    trunc.* = false;
    if (sub.len == 0 or sub[0] == '/' or sub[0] == '\\' or std.mem.indexOf(u8, sub, "..") != null) return 0;
    const fp = std.fmt.allocPrint(gpa, "{s}/{s}/work/{s}", .{ data_dir, rel, sub }) catch return 0;
    defer gpa.free(fp);
    const data = Io.Dir.cwd().readFileAlloc(io, fp, gpa, .limited(2 << 20)) catch return 0;
    defer gpa.free(data);
    const n = @min(data.len, out.len);
    @memcpy(out[0..n], data[0..n]);
    if (data.len > out.len) trunc.* = true;
    return n;
}

/// TCP-probe 127.0.0.1:port — the "server online" signal for the tray + dashboard. Connect-and-close; a
/// dead local port refuses immediately, so no timeout is needed (and this Zig's Windows connect panics on
/// a timeout option — .none is the only portable choice).
pub fn serverOnline(io: Io, port: u16) bool {
    log.trace("scan.serverOnline port={d}", .{port});
    const addr = Io.net.IpAddress{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

/// Drop the STOP sentinel into a run dir. The worker checks it PER TURN (fast), unlike a control.jsonl
/// {"op":"stop"} which only lands at the next ROUND boundary — this is the stop the desktop should reach
/// for first when the user wants a cast gone now.
pub fn writeStop(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, id: []const u8) bool {
    log.trace("scan.writeStop id={s}", .{id});
    const path = std.fmt.allocPrint(gpa, "{s}/{s}/STOP", .{ data_dir, id }) catch return false;
    defer gpa.free(path);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "stop requested by veil-desk\n" }) catch return false;
    return true;
}

/// Write one operator line to a swarm's control.jsonl — the exact bus the worker drains (drainControl):
/// {"op":"say","to":"all","text":"..."} / {"op":"set_goal","goal":"..."} / {"op":"stop"}. Same-machine,
/// so we append directly instead of routing through the authenticated HTTP control endpoint.
pub fn writeControl(io: Io, gpa: std.mem.Allocator, data_dir: []const u8, id: []const u8, line_json: []const u8) bool {
    log.trace("scan.writeControl id={s} line={s}", .{ id, line_json[0..@min(line_json.len, 120)] });
    const path = std.fmt.allocPrint(gpa, "{s}/{s}/control.jsonl", .{ data_dir, id }) catch return false;
    defer gpa.free(path);
    const prior = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 10)) catch &[_]u8{};
    defer if (prior.len > 0) gpa.free(prior);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, prior) catch return false;
    buf.appendSlice(gpa, line_json) catch return false;
    buf.append(gpa, '\n') catch return false;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch return false;
    return true;
}

// --- tests: exercise the parsers on synthetic events, and (best-effort) the real repo data dir ---

test "parseEv composes readable lines and foldMetrics accumulates" {
    const score = "{\"seq\":10,\"kind\":\"score\",\"round\":3,\"passed\":2,\"total\":3,\"pct\":66}";
    var ev: Ev = .{};
    try std.testing.expect(parseEv(score, &ev));
    try std.testing.expectEqualStrings("score", ev.kindStr());
    try std.testing.expect(std.mem.indexOf(u8, ev.textStr(), "2/3") != null);

    var m: Metrics = .{};
    foldMetrics(score, &m);
    foldMetrics("{\"kind\":\"cost\",\"total_in\":1000,\"total_out\":50,\"total_cached\":400,\"calls\":7}", &m);
    foldMetrics("{\"kind\":\"act\",\"tool\":\"gradient\",\"result\":\"invariant\"}", &m);
    foldMetrics("{\"kind\":\"stopped\",\"reason\":\"done\"}", &m);
    try std.testing.expectEqual(@as(i32, 66), m.pct);
    try std.testing.expectEqual(@as(u64, 1000), m.tokens_in);
    try std.testing.expect(m.gradient_warn);
    try std.testing.expect(m.stopped);
    try std.testing.expectEqualStrings("done", m.stop_reason[0..m.stop_reason_len]);
}

test "listWorkFiles parses a .build_manifest and de-dups to latest size" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rel = "zig-scan-tmp"; // under the desktop project dir (test cwd), not the user's data
    _ = Io.Dir.cwd().createDirPathStatus(io, rel, .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, rel) catch {};
    // "path|bytes|valve" lines; app.py appears twice — the later (bigger) size must win, one row only.
    const mani = "app.py|1024|valve\nutils/helpers.py|512|\napp.py|2048|edit\n";
    Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-scan-tmp/.build_manifest", .data = mani }) catch {};
    var out: [MAX_FILES]FileRow = undefined;
    const n = listWorkFiles(io, std.testing.allocator, ".", rel, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    var app_sz: u64 = 0;
    var saw_helpers = false;
    for (out[0..n]) |*f| {
        if (std.mem.eql(u8, f.pathStr(), "app.py")) app_sz = f.size;
        if (std.mem.eql(u8, f.pathStr(), "utils/helpers.py")) saw_helpers = true;
    }
    try std.testing.expectEqual(@as(u64, 2048), app_sz);
    try std.testing.expect(saw_helpers);
}

test "jsonStr unescapes and jsonInt reads negatives" {
    var out: [256]u8 = undefined;
    const line = "{\"a\":\"he said \\\"hi\\\"\",\"round\":-1}";
    const a = jsonStr(line, "a", &out).?;
    try std.testing.expectEqualStrings("he said \"hi\"", a);
    try std.testing.expectEqual(@as(i64, -1), jsonInt(line, "round").?);
}

test "listSwarms over the real repo data dir (best-effort)" {
    // cwd during `zig test` is the desktop/ project dir; the engine's run dirs live one level up.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var now = Io.Timestamp.now(io, .real).nanoseconds;
    const now_s: i64 = @intCast(@divTrunc(now, std.time.ns_per_s));
    var out: [MAX_SWARMS]SwarmSummary = undefined;
    const n = listSwarms(io, std.testing.allocator, "../data", &out, now_s, 45);
    // Not an assertion on count (CI may have no data), just prove it runs and prints what it found.
    std.debug.print("\n[scan test] ../data -> {d} swarm(s)\n", .{n});
    var i: usize = 0;
    while (i < @min(n, 5)) : (i += 1) {
        std.debug.print("  - {s}  r{d} {d}%  live={}\n", .{ out[i].idStr(), out[i].round, out[i].pct, out[i].live });
    }
    now = 0;
}
