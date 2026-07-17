//! metrics.zig — per-turn LLM usage metering behind the desk Dashboard.
//!
//! Every served chat turn (interactive, scheduled task run, console-driven) appends ONE line to
//! `{data}/u{uid}/_metrics/llm.jsonl` when it finishes:
//!
//!   {"ts":<epoch s>,"model":"deepseek-v4-flash","base":"api.deepseek.com","in":73739,"out":2270,"s":41,"sched":1}
//!
//! and GET /api/v1/metrics/llm aggregates that file into what the Dashboard draws: a per-model breakdown
//! (calls, tokens, wall seconds → tokens/sec) plus a 14-local-day activity series. The recorder rides a
//! THREAD-LOCAL turn context armed by engine.runTurn at turn entry — a turn runs start-to-finish on one
//! thread (the same invariant llm.zig's thread-local token counters already lean on), so the usage
//! choke-point (engine.emitUsage) needs no extra parameters threaded through its eleven call sites.
//!
//! Hive/cast minds are NOT metered here yet — they burn tokens on their own threads outside runTurn;
//! per-mind metering is a later lane. At ~110 bytes/turn the file reaches the 16MB read cap after ~150k
//! turns; rotation can land when anyone gets a tenth of the way there.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const sched = @import("sched.zig");

const App = http.App;

// ---- the turn-scoped recorder context (thread-local, armed by engine.runTurn) -------------------------------

const CtxModelMax = 96;
const CtxBaseMax = 160;

const TurnCtx = struct {
    uid: u64 = 0, // 0 = unarmed — record() is a no-op outside a turn
    started: i64 = 0,
    is_sched: bool = false,
    model: [CtxModelMax]u8 = undefined,
    model_len: usize = 0,
    base: [CtxBaseMax]u8 = undefined,
    base_len: usize = 0,
};

threadlocal var cur: TurnCtx = .{};

/// Arm this thread's turn context. Called once at engine.runTurn entry; the strings are COPIED so the
/// caller's buffers can die with the turn blob.
pub fn beginTurn(uid: u64, model: []const u8, base_url: []const u8, is_sched: bool, now_s: i64) void {
    cur.uid = uid;
    cur.started = now_s;
    cur.is_sched = is_sched;
    cur.model_len = @min(model.len, CtxModelMax);
    @memcpy(cur.model[0..cur.model_len], model[0..cur.model_len]);
    const host = hostOf(base_url);
    cur.base_len = @min(host.len, CtxBaseMax);
    @memcpy(cur.base[0..cur.base_len], host[0..cur.base_len]);
}

/// "https://api.deepseek.com/v1" → "api.deepseek.com" (port kept: "127.0.0.1:11434"). The HOST is the
/// stable identity of a provider — paths differ per API shape and keys must never appear here.
pub fn hostOf(base_url: []const u8) []const u8 {
    var s = base_url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
    return std.mem.trim(u8, s, " \r\n\t");
}

/// Append this turn's usage line (called from engine.emitUsage with the turn's token deltas). Quietly does
/// nothing when the thread has no armed context or the turn moved zero tokens. The append is one whole
/// line via http.appendFile — the same torn-write-free discipline events.jsonl uses.
pub fn record(app: *App, tokens_in: u64, tokens_out: u64, tokens_cached: u64, now_s: i64) void {
    if (cur.uid == 0) return;
    if (tokens_in == 0 and tokens_out == 0) return;
    const gpa = app.gpa;
    const dir = std.fmt.allocPrint(gpa, "{s}/u{d}/_metrics", .{ app.data, cur.uid }) catch return;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    const path = std.fmt.allocPrint(gpa, "{s}/llm.jsonl", .{dir}) catch return;
    defer gpa.free(path);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    line.appendSlice(gpa, "{\"ts\":") catch return;
    line.print(gpa, "{d},\"model\":", .{now_s}) catch return;
    http.jstr(gpa, &line, cur.model[0..cur.model_len]) catch return;
    line.appendSlice(gpa, ",\"base\":") catch return;
    http.jstr(gpa, &line, cur.base[0..cur.base_len]) catch return;
    const dur = if (now_s > cur.started and cur.started > 0) now_s - cur.started else 0;
    // `cached`: the provider-cache share of `in` (DeepSeek/Moonshot/OpenAI all report it — llm.zig folds the
    // dialects). A hosted model whose cached share sits near zero is re-prefilling the whole prompt every call.
    line.print(gpa, ",\"in\":{d},\"out\":{d},\"cached\":{d},\"s\":{d},\"sched\":{d}}}\n", .{ tokens_in, tokens_out, tokens_cached, dur, @as(u8, if (cur.is_sched) 1 else 0) }) catch return;
    http.appendFile(app.io, gpa, path, line.items) catch {};
}

/// Disarm (turn over). Not strictly required — the next beginTurn overwrites — but a dead context must
/// never attribute a stray later record on a recycled thread to the finished turn.
pub fn endTurn() void {
    cur.uid = 0;
}

// ---- aggregation (GET /api/v1/metrics/llm) -------------------------------------------------------------------

/// One parsed usage line. Defaults make older/hand-edited lines parse (ignore_unknown covers the reverse).
const Row = struct {
    ts: i64 = 0,
    model: []const u8 = "",
    base: []const u8 = "",
    in: u64 = 0,
    out: u64 = 0,
    cached: u64 = 0, // provider-cache share of `in` (absent on pre-cached lines — defaults 0)
    s: i64 = 0,
    sched: u8 = 0,
};

const MODELS_MAX = 24; // distinct (model, base) pairs the aggregate tracks — more than anyone runs at once
pub const DAYS = 14; // the Dashboard's activity window, in LOCAL days

const ModelAgg = struct {
    model: []const u8 = "",
    base: []const u8 = "",
    calls: u64 = 0,
    in: u64 = 0,
    out: u64 = 0,
    cached: u64 = 0,
    secs: u64 = 0,
    last_ts: i64 = 0,
};

const DayAgg = struct { in: u64 = 0, out: u64 = 0, calls: u64 = 0 };

/// GET /api/v1/metrics/llm — the caller's own usage, aggregated per (model, base) + a DAYS-long local-day
/// series (oldest first; "d" = local epoch-day so the client renders its own labels). Missing file = empty
/// aggregates, never an error: a fresh install has a Dashboard too.
pub fn getLlm(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireUser(app, req, res) orelse return;
    const path = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_metrics/llm.jsonl", .{ app.data, u.id });
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, res.arena, .limited(16 << 20)) catch "";

    var models: [MODELS_MAX]ModelAgg = @splat(.{});
    var mn: usize = 0;
    var days: [DAYS]DayAgg = @splat(.{});
    var tot = ModelAgg{};
    const now = std.Io.Timestamp.now(app.io, .real).toSeconds();
    const today = @divFloor(now + sched.localOffsetSecs(), 86400);

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \r\t");
        if (line.len == 0) continue;
        const r = std.json.parseFromSliceLeaky(Row, res.arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        tot.calls += 1;
        tot.in += r.in;
        tot.out += r.out;
        tot.cached += r.cached;
        tot.secs += @intCast(@max(r.s, 0));
        // per-(model, base) bucket
        var found = false;
        for (models[0..mn]) |*m| {
            if (std.mem.eql(u8, m.model, r.model) and std.mem.eql(u8, m.base, r.base)) {
                bump(m, r);
                found = true;
                break;
            }
        }
        if (!found and mn < MODELS_MAX) {
            models[mn] = .{ .model = r.model, .base = r.base };
            bump(&models[mn], r);
            mn += 1;
        }
        // local-day bucket (index DAYS-1 = today, 0 = DAYS-1 days ago)
        const day = @divFloor(r.ts + sched.localOffsetSecs(), 86400);
        const back = today - day;
        if (back >= 0 and back < DAYS) {
            const d = &days[@intCast(DAYS - 1 - back)];
            d.in += r.in;
            d.out += r.out;
            d.calls += 1;
        }
    }

    // busiest models first — the table reads top-down
    std.mem.sort(ModelAgg, models[0..mn], {}, struct {
        fn lt(_: void, a: ModelAgg, b: ModelAgg) bool {
            return a.in + a.out > b.in + b.out;
        }
    }.lt);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    try out.appendSlice(app.gpa, "{\"ok\":true,\"models\":[");
    for (models[0..mn], 0..) |m, i| {
        if (i > 0) try out.append(app.gpa, ',');
        try out.appendSlice(app.gpa, "{\"model\":");
        try http.jstr(app.gpa, &out, m.model);
        try out.appendSlice(app.gpa, ",\"base\":");
        try http.jstr(app.gpa, &out, m.base);
        try out.print(app.gpa, ",\"calls\":{d},\"in\":{d},\"out\":{d},\"cached\":{d},\"secs\":{d},\"last_ts\":{d}}}", .{ m.calls, m.in, m.out, m.cached, m.secs, m.last_ts });
    }
    try out.appendSlice(app.gpa, "],\"days\":[");
    for (days, 0..) |d, i| {
        if (i > 0) try out.append(app.gpa, ',');
        const day = today - @as(i64, @intCast(DAYS - 1 - i));
        try out.print(app.gpa, "{{\"d\":{d},\"in\":{d},\"out\":{d},\"calls\":{d}}}", .{ day, d.in, d.out, d.calls });
    }
    try out.print(app.gpa, "],\"totals\":{{\"calls\":{d},\"in\":{d},\"out\":{d},\"cached\":{d},\"secs\":{d}}}}}", .{ tot.calls, tot.in, tot.out, tot.cached, tot.secs });
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, out.items);
}

fn bump(m: *ModelAgg, r: Row) void {
    m.calls += 1;
    m.in += r.in;
    m.out += r.out;
    m.cached += r.cached;
    m.secs += @intCast(@max(r.s, 0));
    if (r.ts > m.last_ts) m.last_ts = r.ts;
}

// ---- tests ---------------------------------------------------------------------------------------------------

test "hostOf strips scheme + path, keeps host:port, tolerates bare hosts" {
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com/v1"));
    try std.testing.expectEqualStrings("127.0.0.1:11434", hostOf("http://127.0.0.1:11434/v1"));
    try std.testing.expectEqualStrings("api.openai.com", hostOf("api.openai.com/v1"));
    try std.testing.expectEqualStrings("localhost", hostOf("localhost"));
    try std.testing.expectEqualStrings("", hostOf(""));
}

test "usage line round-trips through the Row parser (unknown fields ignored)" {
    const gpa = std.testing.allocator;
    const line = "{\"ts\":1784165341,\"model\":\"deepseek-v4-flash\",\"base\":\"api.deepseek.com\",\"in\":73739,\"out\":2270,\"s\":41,\"sched\":1,\"future\":true}";
    const parsed = try std.json.parseFromSlice(Row, gpa, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1784165341), parsed.value.ts);
    try std.testing.expectEqualStrings("deepseek-v4-flash", parsed.value.model);
    try std.testing.expectEqual(@as(u64, 73739), parsed.value.in);
    try std.testing.expectEqual(@as(u64, 2270), parsed.value.out);
    try std.testing.expectEqual(@as(i64, 41), parsed.value.s);
    try std.testing.expectEqual(@as(u8, 1), parsed.value.sched);
}

test "beginTurn/record context: hostOf lands in base, unarmed thread is a no-op shape" {
    beginTurn(7, "m1", "https://api.deepseek.com/v1", true, 1000);
    try std.testing.expectEqual(@as(u64, 7), cur.uid);
    try std.testing.expectEqualStrings("api.deepseek.com", cur.base[0..cur.base_len]);
    try std.testing.expectEqualStrings("m1", cur.model[0..cur.model_len]);
    try std.testing.expect(cur.is_sched);
    endTurn();
    try std.testing.expectEqual(@as(u64, 0), cur.uid);
}
