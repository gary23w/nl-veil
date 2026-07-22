//! chat/toolperf.zig — per-machine tool-performance LEARNING (dynamic, emergent; no hardcoded expectations).
//!
//! The engine times every tool call and tallies (name, ok/fail, latency). At turn exit those tallies merge
//! into a small persistent aggregate at {data}/.tool_perf.json — one row per tool with a running call/fail
//! count and an EWMA latency (recent behavior dominates). At turn start the engine asks digest() for a compact
//! line naming only the NOTABLE tools (slow or flaky, with enough samples) and injects it into the prompt, so
//! the agent plans around how tools ACTUALLY behave on this machine (a cold browser is slow here; that endpoint
//! keeps 404ing) instead of re-learning it every run. This is the substrate's no-hardcoded-use-cases rule
//! applied to tool latency/reliability: the guidance is grown from live signals, never baked in.

const std = @import("std");

pub const MAX_TOOLS = 48; // distinct tool names tracked (well above the real tool count)
const EWMA_ALPHA: f64 = 0.3; // weight of the newest turn's average in the running latency
const NOTABLE_SLOW_MS: u64 = 3000; // a tool averaging slower than this is worth telling the model about
const NOTABLE_FAIL_PCT: u64 = 25; // ... or one that fails at least this often
const MIN_SAMPLES: u32 = 3; // don't report a tool until it has acted a few times (avoid noise)
const MAX_DIGEST_TOOLS = 8; // cap the injected line
const FILE_CAP: usize = 64 << 10; // the aggregate stays tiny; a corrupt/huge file is ignored

/// One tool's turn-local tally, before it's merged into the persistent aggregate.
const Row = struct {
    name: [48]u8 = undefined,
    name_len: usize = 0,
    calls: u32 = 0,
    fails: u32 = 0,
    total_ms: u64 = 0,
    fn nameStr(r: *const Row) []const u8 {
        return r.name[0..r.name_len];
    }
};

/// Per-turn accumulator: the drive loop calls record() after each executed tool; runTurn merges it once at
/// turn exit. Fixed-size and stack-lived — it can never grow unbounded or outlive the turn.
pub const Acc = struct {
    rows: [MAX_TOOLS]Row = .{Row{}} ** MAX_TOOLS,
    n: usize = 0,

    /// Tally one tool call. `ok` is the engine's success read (a real result, not an error/`"ok":false`);
    /// `ms` is its wall latency. Only calls that genuinely executed should be recorded (skip dedup/budget
    /// guards — they never ran the tool), so a guard can't smear a real tool's fail rate.
    pub fn record(self: *Acc, name: []const u8, ok: bool, ms: u64) void {
        if (name.len == 0) return;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (std.mem.eql(u8, self.rows[i].nameStr(), name)) break;
        }
        if (i == self.n) {
            if (self.n >= MAX_TOOLS) return; // registry full — drop silently (bounded)
            const nl = @min(name.len, self.rows[i].name.len);
            @memcpy(self.rows[i].name[0..nl], name[0..nl]);
            self.rows[i].name_len = nl;
            self.n += 1;
        }
        self.rows[i].calls += 1;
        if (!ok) self.rows[i].fails += 1;
        self.rows[i].total_ms += ms;
    }
};

/// A one-line record of what THIS turn actually ran: "browser_click x40 ok, run_python x41 (3 failed)".
/// Null when nothing ran. Caller frees.
///
/// This exists for the post-answer critique, which is asked to catch "a claim that contradicts what the
/// tools actually returned" — and was never shown what the tools returned. Guessing from the answer alone,
/// it repeatedly told users the assistant COULD NOT do things this ledger proves it had just done: denying
/// a browser it had driven 31 times, denying Python it had run 41 times. A confident false correction is
/// worse than no correction, so the critique is now given the record instead of asked to imagine it.
pub fn ledger(self: *const Acc, gpa: std.mem.Allocator) ?[]u8 {
    if (self.n == 0) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < self.n) : (i += 1) {
        const r = &self.rows[i];
        var buf: [96]u8 = undefined;
        const row = if (r.fails > 0)
            std.fmt.bufPrint(&buf, "{s}{s} x{d} ({d} failed)", .{ if (out.items.len > 0) ", " else "", r.nameStr(), r.calls, r.fails })
        else
            std.fmt.bufPrint(&buf, "{s}{s} x{d} ok", .{ if (out.items.len > 0) ", " else "", r.nameStr(), r.calls });
        out.appendSlice(gpa, row catch continue) catch {
            out.deinit(gpa);
            return null;
        };
    }
    if (out.items.len == 0) return null;
    return out.toOwnedSlice(gpa) catch null;
}

test "ledger names what ran and flags failures; null when nothing ran" {
    const gpa = std.testing.allocator;
    var acc = Acc{};
    try std.testing.expect(ledger(&acc, gpa) == null);
    acc.record("browser_navigate", true, 10);
    acc.record("browser_navigate", true, 10);
    acc.record("run_python", false, 5);
    const s = ledger(&acc, gpa).?;
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "browser_navigate x2 ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "run_python x1 (1 failed)") != null);
}

// The persistent JSON shape: n=total calls, f=total fails, ms=EWMA per-call latency.
const PRow = struct { name: []const u8 = "", n: u32 = 0, f: u32 = 0, ms: u64 = 0 };
const Persist = struct { v: u32 = 1, tools: []PRow = &.{} };

fn filePath(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    return std.fmt.allocPrint(gpa, "{s}/.tool_perf.json", .{data}) catch null;
}

/// Merge this turn's tallies into {data}/.tool_perf.json (load → EWMA-update → write). Best-effort: any read
/// error starts from an empty aggregate; any write error just drops this turn's learning (never fatal).
pub fn merge(io: std.Io, gpa: std.mem.Allocator, data: []const u8, acc: *const Acc) void {
    if (acc.n == 0) return;
    const path = filePath(gpa, data) orelse return;
    defer gpa.free(path);

    // load the existing aggregate into a mutable working set (fixed-size, bounded by MAX_TOOLS)
    var names: [MAX_TOOLS][48]u8 = undefined;
    var name_lens: [MAX_TOOLS]usize = .{0} ** MAX_TOOLS;
    var ns: [MAX_TOOLS]u32 = .{0} ** MAX_TOOLS;
    var fs: [MAX_TOOLS]u32 = .{0} ** MAX_TOOLS;
    var msv: [MAX_TOOLS]u64 = .{0} ** MAX_TOOLS;
    var count: usize = 0;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(FILE_CAP)) catch null) |raw| {
        defer gpa.free(raw);
        if (std.json.parseFromSlice(Persist, gpa, raw, .{ .ignore_unknown_fields = true }) catch null) |parsed| {
            defer parsed.deinit();
            for (parsed.value.tools) |t| {
                if (count >= MAX_TOOLS or t.name.len == 0) break;
                const nl = @min(t.name.len, names[count].len);
                @memcpy(names[count][0..nl], t.name[0..nl]);
                name_lens[count] = nl;
                ns[count] = t.n;
                fs[count] = t.f;
                msv[count] = t.ms;
                count += 1;
            }
        }
    }

    // fold in each turn tally: EWMA the latency toward this turn's per-call average
    var ri: usize = 0;
    while (ri < acc.n) : (ri += 1) {
        const r = &acc.rows[ri];
        if (r.calls == 0) continue;
        const turn_avg: f64 = @as(f64, @floatFromInt(r.total_ms)) / @as(f64, @floatFromInt(r.calls));
        var j: usize = 0;
        while (j < count) : (j += 1) {
            if (std.mem.eql(u8, names[j][0..name_lens[j]], r.nameStr())) break;
        }
        if (j == count) {
            if (count >= MAX_TOOLS) continue;
            const nl = @min(r.name_len, names[count].len);
            @memcpy(names[count][0..nl], r.name[0..nl]);
            name_lens[count] = nl;
            ns[count] = 0;
            fs[count] = 0;
            msv[count] = 0;
            count += 1;
            j = count - 1;
        }
        const prior_ms: f64 = @floatFromInt(msv[j]);
        const blended: f64 = if (ns[j] == 0) turn_avg else (EWMA_ALPHA * turn_avg + (1.0 - EWMA_ALPHA) * prior_ms);
        msv[j] = @intFromFloat(@max(0.0, blended));
        ns[j] +|= r.calls;
        fs[j] +|= r.fails;
    }

    // serialize back (hand-rolled: tiny object, avoids allocating a temp slice of structs)
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"v\":1,\"tools\":[") catch return;
    var wrote: usize = 0;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (name_lens[k] == 0) continue;
        if (wrote > 0) out.append(gpa, ',') catch return;
        out.appendSlice(gpa, "{\"name\":") catch return;
        writeJsonStr(gpa, &out, names[k][0..name_lens[k]]) catch return;
        out.print(gpa, ",\"n\":{d},\"f\":{d},\"ms\":{d}}}", .{ ns[k], fs[k], msv[k] }) catch return;
        wrote += 1;
    }
    out.appendSlice(gpa, "]}") catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// A compact prompt line naming the NOTABLE tools (slow or flaky, with enough samples) learned on this
/// machine — or null when nothing is worth saying. gpa-owned; caller frees. Deterministic ordering (worst
/// first: highest fail rate, then slowest) so the line is stable across turns when the data hasn't moved.
pub fn digest(gpa: std.mem.Allocator, io: std.Io, data: []const u8) ?[]u8 {
    const path = filePath(gpa, data) orelse return null;
    defer gpa.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(FILE_CAP)) catch return null;
    defer gpa.free(raw);
    const parsed = std.json.parseFromSlice(Persist, gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    // collect notable tools, worst-first
    const Item = struct { name: []const u8, n: u32, f: u32, ms: u64, fail_pct: u64 };
    var items: [MAX_TOOLS]Item = undefined;
    var ni: usize = 0;
    for (parsed.value.tools) |t| {
        if (ni >= MAX_TOOLS or t.name.len == 0 or t.n < MIN_SAMPLES) continue;
        const fail_pct: u64 = if (t.n > 0) (@as(u64, t.f) * 100) / t.n else 0;
        if (t.ms < NOTABLE_SLOW_MS and fail_pct < NOTABLE_FAIL_PCT) continue;
        items[ni] = .{ .name = t.name, .n = t.n, .f = t.f, .ms = t.ms, .fail_pct = fail_pct };
        ni += 1;
    }
    if (ni == 0) return null;
    // simple insertion sort (ni is tiny): flakier first, then slower
    var a: usize = 1;
    while (a < ni) : (a += 1) {
        const cur = items[a];
        var b: usize = a;
        while (b > 0 and lessBad(items[b - 1], cur)) : (b -= 1) items[b] = items[b - 1];
        items[b] = cur;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "TOOL BEHAVIOR ON THIS MACHINE (learned from past runs — plan around it): ") catch return null;
    const limit = @min(ni, MAX_DIGEST_TOOLS);
    var w: usize = 0;
    while (w < limit) : (w += 1) {
        const it = items[w];
        if (w > 0) out.appendSlice(gpa, "; ") catch return null;
        if (it.fail_pct >= NOTABLE_FAIL_PCT) {
            out.print(gpa, "{s} fails ~{d}% ({d}/{d}) — verify it or use another path", .{ it.name, it.fail_pct, it.f, it.n }) catch return null;
        } else {
            const secs = @as(f64, @floatFromInt(it.ms)) / 1000.0;
            out.print(gpa, "{s} is slow here (~{d:.1}s avg) — expect the wait, don't retry early", .{ it.name, secs }) catch return null;
        }
    }
    out.append(gpa, '.') catch return null;
    return gpa.dupe(u8, out.items) catch null;
}

/// True when `x` is LESS bad than `y` (used by the descending insertion sort): fewer fails first, then faster.
fn lessBad(x: anytype, y: anytype) bool {
    if (x.fail_pct != y.fail_pct) return x.fail_pct < y.fail_pct;
    return x.ms < y.ms;
}

/// Append `s` as a JSON string literal (quotes + minimal escaping) — tool names are safe identifiers, but
/// escape defensively so a stray control byte can never corrupt the aggregate file.
fn writeJsonStr(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [6]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
        } else try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

// ------------------------------------------------------------------------------------------------- tests

test "Acc.record tallies calls, fails, and latency per tool" {
    var acc: Acc = .{};
    acc.record("browser_navigate", true, 2000);
    acc.record("browser_navigate", true, 2200);
    acc.record("flaky", false, 50);
    acc.record("flaky", true, 40);
    try std.testing.expectEqual(@as(usize, 2), acc.n);
    // find the browser row
    var bn: ?*const Row = null;
    for (acc.rows[0..acc.n]) |*r| {
        if (std.mem.eql(u8, r.nameStr(), "browser_navigate")) bn = r;
    }
    try std.testing.expect(bn != null);
    try std.testing.expectEqual(@as(u32, 2), bn.?.calls);
    try std.testing.expectEqual(@as(u32, 0), bn.?.fails);
    try std.testing.expectEqual(@as(u64, 4200), bn.?.total_ms);
}

test "digest names slow and flaky tools, skips fast/reliable and low-sample ones" {
    const gpa = std.testing.allocator;
    // a hand-built aggregate: slow (browser), flaky (fetch), fine (write), too-few-samples (rare)
    const json =
        \\{"v":1,"tools":[
        \\{"name":"browser_navigate","n":10,"f":0,"ms":40000},
        \\{"name":"fetch_json","n":8,"f":4,"ms":300},
        \\{"name":"write_file","n":20,"f":0,"ms":80},
        \\{"name":"rare_tool","n":1,"f":1,"ms":9000}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(Persist, gpa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    // exercise the notable-selection logic the way digest() does, without touching the filesystem
    var slow_seen = false;
    var flaky_seen = false;
    var fast_seen = false;
    var rare_seen = false;
    for (parsed.value.tools) |t| {
        const fail_pct: u64 = if (t.n > 0) (@as(u64, t.f) * 100) / t.n else 0;
        const notable = t.n >= MIN_SAMPLES and (t.ms >= NOTABLE_SLOW_MS or fail_pct >= NOTABLE_FAIL_PCT);
        if (std.mem.eql(u8, t.name, "browser_navigate")) slow_seen = notable;
        if (std.mem.eql(u8, t.name, "fetch_json")) flaky_seen = notable;
        if (std.mem.eql(u8, t.name, "write_file")) fast_seen = notable;
        if (std.mem.eql(u8, t.name, "rare_tool")) rare_seen = notable;
    }
    try std.testing.expect(slow_seen); // 40s avg → reported
    try std.testing.expect(flaky_seen); // 50% fail → reported
    try std.testing.expect(!fast_seen); // fast + reliable → silent
    try std.testing.expect(!rare_seen); // only 1 sample → below MIN_SAMPLES
}
