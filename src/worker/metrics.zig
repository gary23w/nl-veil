//! metrics.zig — per-ROLE LLM usage metering behind the desk Dashboard.
//!
//! Every served chat turn (interactive, scheduled task run, console-driven) appends one line PER (role, model)
//! to `{data}/u{uid}/_metrics/llm.jsonl` when it finishes:
//!
//!   {"ts":<epoch s>,"role":"chat","model":"kimi-k3","base":"api.moonshot.ai",
//!    "calls":3,"in":92214,"out":1204,"cached":43980,"ms":18450,"s":18,"sched":0}
//!
//! and GET /api/v1/metrics/llm aggregates that file into what the Dashboard draws: a per-model breakdown, a
//! per-(role, model) breakdown, and a 14-local-day activity series.
//!
//! WHY PER ROLE. Under the model trio a turn is served by up to three DIFFERENT models routed by call label
//! (chat→coding, loop→prompting, plan/reflect/summary/ctxsum/compact/lesson→thinking). This recorder used to
//! write one line per turn stamped with whichever model armed it, fed by a thread-local token counter that
//! every call on the thread bumped regardless of who served it — so the thinking and prompting models' tokens
//! were billed to the coding model's row, and the file could not represent a trio at all. The split is now
//! measured in llm.zig at the usage fold, where the call's label and its actual model are both in hand
//! (llm.roleCosts); this file drains and writes it. See llm.zig's PER-ROLE COST ATTRIBUTION section.
//!
//! Two files, because they answer different questions at different sizes:
//!   llm.jsonl   — per (role, model) per TURN. What the Dashboard aggregates. Bounded like the old one.
//!   calls.jsonl — per CALL: role, model, base, latency, tokens. The durable flight recorder, the thing that
//!                 answers "which model served THAT call, and why did it take 40s". Rotates at CALLS_MAX.
//!
//! The recorder rides a THREAD-LOCAL turn context armed by engine.runTurn at turn entry — a turn runs
//! start-to-finish on one thread (the same invariant llm.zig's thread-local counters already lean on), so the
//! usage choke-point (engine.emitUsage) needs no extra parameters threaded through its eleven call sites.
//!
//! Hive/cast minds are NOT metered here yet — they burn tokens on their own threads outside runTurn;
//! per-mind metering is a later lane. At ~150 bytes/row the aggregate file reaches the 16MB read cap after
//! ~100k turns; rotation can land when anyone gets a tenth of the way there.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const sched = @import("sched.zig");
const llm = @import("llm.zig");

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
    // Tokens this turn has already written rows for. record() is handed a delta measured from the turn's START
    // snapshot, so it is CUMULATIVE — and the engine reaches its usage choke-point from nine different
    // completion paths. Without this, a turn that emitted usage twice would book its whole cost twice. The
    // reconciliation subtracts what is already on disk, so a repeat call writes nothing.
    billed_in: u64 = 0,
    billed_out: u64 = 0,
    billed_cached: u64 = 0,
};

threadlocal var cur: TurnCtx = .{};

/// The App, cached from the first record(). endTurn() has no App parameter (engine.zig owns that signature and
/// calls it from a `defer`), but it still has to flush any calls the turn made AFTER the usage snapshot — the
/// deferred rolling-summary refresh is real spend on a real model. One long-lived server object, written with
/// the same pointer every time.
var app_cache: std.atomic.Value(?*App) = .init(null);

/// Arm this thread's turn context. Called once at engine.runTurn entry; the strings are COPIED so the
/// caller's buffers can die with the turn blob.
///
/// `model`/`base_url` are the CODING model — under a trio they describe only one of the three. They are no
/// longer the attribution (llm.zig measures that per call); they are the fallback stamp for tokens that
/// reached the meter without a role, and the identity of the turn's primary model.
pub fn beginTurn(uid: u64, model: []const u8, base_url: []const u8, is_sched: bool, now_s: i64) void {
    cur.uid = uid;
    cur.started = now_s;
    cur.is_sched = is_sched;
    cur.model_len = @min(model.len, CtxModelMax);
    @memcpy(cur.model[0..cur.model_len], model[0..cur.model_len]);
    const host = hostOf(base_url);
    cur.base_len = @min(host.len, CtxBaseMax);
    @memcpy(cur.base[0..cur.base_len], host[0..cur.base_len]);
    cur.billed_in = 0;
    cur.billed_out = 0;
    cur.billed_cached = 0;
    // A recycled thread must never bill this turn for its predecessor's calls.
    llm.resetAttribution();
}

/// "https://api.deepseek.com/v1" → "api.deepseek.com" (port kept: "127.0.0.1:11434"). The HOST is the
/// stable identity of a provider — paths differ per API shape and keys must never appear here.
pub fn hostOf(base_url: []const u8) []const u8 {
    var s = base_url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
    return std.mem.trim(u8, s, " \r\n\t");
}

/// Once calls.jsonl passes this, it rotates to calls.prev.jsonl (replacing any older rotation) so exactly one
/// previous window stays inspectable and the flight recorder can never eat the disk.
const CALLS_MAX: u64 = 32 << 20;

/// Append this turn's usage (called from engine.emitUsage with the turn's token deltas). Writes one line per
/// (role, model) the turn actually used, plus the buffered per-call flight lines. Quietly does nothing when the
/// thread has no armed context or the turn moved zero tokens. Each file gets ONE http.appendFile — the same
/// torn-write-free discipline events.jsonl uses, and rows for a turn stay contiguous.
pub fn record(app: *App, tokens_in: u64, tokens_out: u64, tokens_cached: u64, now_s: i64) void {
    app_cache.store(app, .monotonic); // endTurn() has no App of its own — see app_cache
    if (cur.uid == 0) return;
    if (tokens_in == 0 and tokens_out == 0) return;
    flush(app, tokens_in, tokens_out, tokens_cached, now_s);
}

/// Write whatever llm.zig has accumulated for this turn. `d_*` is the turn's token delta as the engine
/// measured it; anything it covers that the per-role buckets do NOT is written as one `"other"` row against
/// the armed model, so the file's totals always reconcile with the turn's real spend even if some future call
/// path reaches the token meter without going through a fold site that attributes.
fn flush(app: *App, d_in: u64, d_out: u64, d_cached: u64, now_s: i64) void {
    const gpa = app.gpa;
    const roles = llm.roleCosts();
    const calls_log = llm.callLog();
    if (roles.len == 0 and calls_log.len == 0 and d_in == 0 and d_out == 0) return;

    const dir = std.fmt.allocPrint(gpa, "{s}/u{d}/_metrics", .{ app.data, cur.uid }) catch return;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};

    var rows: std.ArrayListUnmanaged(u8) = .empty;
    defer rows.deinit(gpa);
    var acc_in: u64 = 0;
    var acc_out: u64 = 0;
    var acc_cached: u64 = 0;
    for (roles) |*b| {
        acc_in += b.in;
        acc_out += b.out;
        acc_cached += b.cached;
        appendRow(gpa, &rows, now_s, b.label(), b.model(), hostOf(b.base()), b.calls, b.in, b.out, b.cached, b.ms) catch return;
    }
    // What the engine's (cumulative) delta covers that neither this flush's rows nor an earlier flush's rows
    // account for. Saturating throughout: buckets can only EXCEED the delta when a call landed between
    // beginTurn and the engine's pre-turn snapshot, and those tokens already have a row of their own.
    const rem_in = d_in -| cur.billed_in -| acc_in;
    const rem_out = d_out -| cur.billed_out -| acc_out;
    const rem_cached = d_cached -| cur.billed_cached -| acc_cached;
    if (rem_in > 0 or rem_out > 0) {
        // No per-call latency for unattributed tokens, so fall back to turn wall time for this row alone.
        const dur_ms: u64 = if (now_s > cur.started and cur.started > 0) @intCast((now_s - cur.started) * 1000) else 0;
        appendRow(gpa, &rows, now_s, "other", cur.model[0..cur.model_len], cur.base[0..cur.base_len], 1, rem_in, rem_out, rem_cached, dur_ms) catch return;
    }
    cur.billed_in += acc_in + rem_in;
    cur.billed_out += acc_out + rem_out;
    // Accrued OUTSIDE the row guard above, and the placement is the point: a flush whose remainder is
    // cached-ONLY (rem_in and rem_out both zero) emits no row, and while this accrual rode along inside the
    // guard those cached tokens stayed unbilled — so the next flush that DID emit an "other" row counted them
    // a second time. Marking them billed without a row is right: there is no in/out to report, but they must
    // not be reported twice.
    cur.billed_cached += acc_cached + rem_cached;

    if (rows.items.len > 0) {
        const path = std.fmt.allocPrint(gpa, "{s}/llm.jsonl", .{dir}) catch return;
        defer gpa.free(path);
        http.appendFile(app.io, gpa, path, rows.items) catch {};
    }
    if (calls_log.len > 0) writeCallLog(app, gpa, dir, calls_log);
    llm.resetAttribution(); // drained — a second record() on this turn must not double-bill
}

/// One `{...}` row of llm.jsonl. `s` is `ms` rounded, kept so older readers (and eyeballs) still work; `ms` is
/// the precise value and the one to aggregate. Both are PROVIDER latency summed over the bucket's calls, not
/// turn wall clock — a turn's roles run in sequence inside it, so wall clock would let every role claim the
/// same seconds and make each model look three times slower than it is.
fn appendRow(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), ts: i64, role: []const u8, model: []const u8, base: []const u8, calls: u64, t_in: u64, t_out: u64, t_cached: u64, ms: u64) !void {
    try out.print(gpa, "{{\"ts\":{d},\"role\":", .{ts});
    try http.jstr(gpa, out, role);
    try out.appendSlice(gpa, ",\"model\":");
    try http.jstr(gpa, out, model);
    try out.appendSlice(gpa, ",\"base\":");
    try http.jstr(gpa, out, base);
    // `cached`: the provider-cache share of `in` (DeepSeek/Moonshot/OpenAI all report it — llm.zig folds the
    // dialects). A hosted model whose cached share sits near zero is re-prefilling the whole prompt every call.
    try out.print(gpa, ",\"calls\":{d},\"in\":{d},\"out\":{d},\"cached\":{d},\"ms\":{d},\"s\":{d},\"sched\":{d}}}\n", .{ calls, t_in, t_out, t_cached, ms, @divTrunc(ms, 1000), @as(u8, if (cur.is_sched) 1 else 0) });
}

/// Append the buffered flight lines, rotating first if the log has grown past CALLS_MAX. Lines arrive
/// pre-rendered from llm.zig (fixed-buffer, no allocator on the call path) so this just moves bytes.
fn writeCallLog(app: *App, gpa: std.mem.Allocator, dir: []const u8, lines: []const u8) void {
    const path = std.fmt.allocPrint(gpa, "{s}/calls.jsonl", .{dir}) catch return;
    defer gpa.free(path);
    if (std.Io.Dir.cwd().statFile(app.io, path, .{})) |st| {
        if (st.size > CALLS_MAX) {
            const prev = std.fmt.allocPrint(gpa, "{s}/calls.prev.jsonl", .{dir}) catch return;
            defer gpa.free(prev);
            std.Io.Dir.cwd().deleteFile(app.io, prev) catch {};
            std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), prev, app.io) catch {};
        }
    } else |_| {}
    http.appendFile(app.io, gpa, path, lines) catch {};
    // A dropped flight line means the log undercounts CALLS; the token totals in llm.jsonl are still whole.
    const dropped = llm.callLogDropped();
    if (dropped > 0) std.log.warn("metrics: {d} flight line(s) dropped this turn (call-log buffer full)", .{dropped});
}

/// Disarm (turn over). Not strictly required for the context — the next beginTurn overwrites — but a dead
/// context must never attribute a stray later record on a recycled thread to the finished turn.
///
/// It IS required for the attribution buckets: the engine snapshots usage BEFORE its deferred end-of-turn
/// maintenance (the rolling-summary refresh), so those calls land after record() and would otherwise be
/// dropped on the floor. Flushing them here books them to their own roles instead of vanishing.
pub fn endTurn() void {
    if (cur.uid != 0 and llm.roleCosts().len > 0) {
        if (app_cache.load(.monotonic)) |app| {
            const now = std.Io.Timestamp.now(app.io, .real).toSeconds();
            flush(app, 0, 0, 0, now); // zero delta: the buckets ARE the truth, no remainder row
        }
    }
    llm.resetAttribution();
    cur.uid = 0;
}

// ---- aggregation (GET /api/v1/metrics/llm) -------------------------------------------------------------------

/// One parsed usage line. Defaults make older/hand-edited lines parse (ignore_unknown covers the reverse), so
/// the pre-role rows already on disk still aggregate: they land under role "" with calls 1 and no `ms`.
const Row = struct {
    ts: i64 = 0,
    role: []const u8 = "", // "" = written before per-role attribution existed
    model: []const u8 = "",
    base: []const u8 = "",
    calls: u64 = 1, // a row now covers every call of one (role, model) in one turn
    in: u64 = 0,
    out: u64 = 0,
    cached: u64 = 0, // provider-cache share of `in` (absent on pre-cached lines — defaults 0)
    ms: u64 = 0, // summed provider latency (absent on legacy rows — `s` carries turn wall time instead)
    s: i64 = 0,
    sched: u8 = 0,

    /// Latency in ms however this row spells it. Legacy rows only carry whole seconds of TURN wall clock;
    /// that over-states a single model's time but is the only number they have.
    fn millis(r: Row) u64 {
        return if (r.ms > 0) r.ms else @intCast(@max(r.s, 0) * 1000);
    }
};

const MODELS_MAX = 24; // distinct (model, base) pairs the aggregate tracks — more than anyone runs at once
const ROLES_MAX = 48; // distinct (role, model, base) triples — the trio's eight labels across a few models
pub const DAYS = 14; // the Dashboard's activity window, in LOCAL days

const ModelAgg = struct {
    role: []const u8 = "", // "" in the per-model table; set in the per-role table
    model: []const u8 = "",
    base: []const u8 = "",
    calls: u64 = 0,
    in: u64 = 0,
    out: u64 = 0,
    cached: u64 = 0,
    ms: u64 = 0,
    last_ts: i64 = 0,
};

const DayAgg = struct { in: u64 = 0, out: u64 = 0, calls: u64 = 0 };

/// GET /api/v1/metrics/llm — the caller's own usage, aggregated per (model, base), per (role, model, base),
/// and into a DAYS-long local-day series (oldest first; "d" = local epoch-day so the client renders its own
/// labels). Missing file = empty aggregates, never an error: a fresh install has a Dashboard too.
///
/// `models` and `roles` are two views of the SAME rows — `roles` answers "what is each role costing me?",
/// `models` answers "what is each model costing me?", and under a single-model config the two agree.
pub fn getLlm(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireUser(app, req, res) orelse return;
    const path = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_metrics/llm.jsonl", .{ app.data, u.id });
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, res.arena, .limited(16 << 20)) catch "";

    var models: [MODELS_MAX]ModelAgg = @splat(.{});
    var mn: usize = 0;
    var roles: [ROLES_MAX]ModelAgg = @splat(.{});
    var rn: usize = 0;
    var days: [DAYS]DayAgg = @splat(.{});
    var tot = ModelAgg{};
    const now = std.Io.Timestamp.now(app.io, .real).toSeconds();
    const today = @divFloor(now + sched.localOffsetSecs(), 86400);

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \r\t");
        if (line.len == 0) continue;
        const r = std.json.parseFromSliceLeaky(Row, res.arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        tot.calls += r.calls;
        tot.in += r.in;
        tot.out += r.out;
        tot.cached += r.cached;
        tot.ms += r.millis();
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
        // per-(role, model, base) bucket — the trio breakdown
        var rfound = false;
        for (roles[0..rn]) |*m| {
            if (std.mem.eql(u8, m.role, r.role) and std.mem.eql(u8, m.model, r.model) and std.mem.eql(u8, m.base, r.base)) {
                bump(m, r);
                rfound = true;
                break;
            }
        }
        if (!rfound and rn < ROLES_MAX) {
            roles[rn] = .{ .role = r.role, .model = r.model, .base = r.base };
            bump(&roles[rn], r);
            rn += 1;
        }
        // local-day bucket (index DAYS-1 = today, 0 = DAYS-1 days ago)
        const day = @divFloor(r.ts + sched.localOffsetSecs(), 86400);
        const back = today - day;
        if (back >= 0 and back < DAYS) {
            const d = &days[@intCast(DAYS - 1 - back)];
            d.in += r.in;
            d.out += r.out;
            d.calls += r.calls;
        }
    }

    // busiest first — both tables read top-down
    const byTokens = struct {
        fn lt(_: void, a: ModelAgg, b: ModelAgg) bool {
            return a.in + a.out > b.in + b.out;
        }
    }.lt;
    std.mem.sort(ModelAgg, models[0..mn], {}, byTokens);
    std.mem.sort(ModelAgg, roles[0..rn], {}, byTokens);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    try out.appendSlice(app.gpa, "{\"ok\":true,\"models\":[");
    for (models[0..mn], 0..) |m, i| {
        if (i > 0) try out.append(app.gpa, ',');
        try emitAgg(app.gpa, &out, m, false);
    }
    try out.appendSlice(app.gpa, "],\"roles\":[");
    for (roles[0..rn], 0..) |m, i| {
        if (i > 0) try out.append(app.gpa, ',');
        try emitAgg(app.gpa, &out, m, true);
    }
    try out.appendSlice(app.gpa, "],\"days\":[");
    for (days, 0..) |d, i| {
        if (i > 0) try out.append(app.gpa, ',');
        const day = today - @as(i64, @intCast(DAYS - 1 - i));
        try out.print(app.gpa, "{{\"d\":{d},\"in\":{d},\"out\":{d},\"calls\":{d}}}", .{ day, d.in, d.out, d.calls });
    }
    try out.print(app.gpa, "],\"totals\":{{\"calls\":{d},\"in\":{d},\"out\":{d},\"cached\":{d},\"ms\":{d},\"secs\":{d}}}}}", .{ tot.calls, tot.in, tot.out, tot.cached, tot.ms, @divTrunc(tot.ms, 1000) });
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, out.items);
}

/// One aggregate object. `secs` stays for the existing Dashboard columns; `ms` is the precise twin, and the
/// one to divide tokens by when showing tokens/sec.
fn emitAgg(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), m: ModelAgg, with_role: bool) !void {
    try out.appendSlice(gpa, "{");
    if (with_role) {
        try out.appendSlice(gpa, "\"role\":");
        try http.jstr(gpa, out, m.role);
        try out.appendSlice(gpa, ",");
    }
    try out.appendSlice(gpa, "\"model\":");
    try http.jstr(gpa, out, m.model);
    try out.appendSlice(gpa, ",\"base\":");
    try http.jstr(gpa, out, m.base);
    try out.print(gpa, ",\"calls\":{d},\"in\":{d},\"out\":{d},\"cached\":{d},\"ms\":{d},\"secs\":{d},\"last_ts\":{d}}}", .{ m.calls, m.in, m.out, m.cached, m.ms, @divTrunc(m.ms, 1000), m.last_ts });
}

fn bump(m: *ModelAgg, r: Row) void {
    m.calls += r.calls;
    m.in += r.in;
    m.out += r.out;
    m.cached += r.cached;
    m.ms += r.millis();
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

test "LEGACY usage line still parses: no role, no calls, no ms — one call, wall-clock latency" {
    const gpa = std.testing.allocator;
    const line = "{\"ts\":1784165341,\"model\":\"deepseek-v4-flash\",\"base\":\"api.deepseek.com\",\"in\":73739,\"out\":2270,\"s\":41,\"sched\":1,\"future\":true}";
    const parsed = try std.json.parseFromSlice(Row, gpa, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const r = parsed.value;
    try std.testing.expectEqual(@as(i64, 1784165341), r.ts);
    try std.testing.expectEqualStrings("deepseek-v4-flash", r.model);
    try std.testing.expectEqual(@as(u64, 73739), r.in);
    try std.testing.expectEqual(@as(u64, 2270), r.out);
    try std.testing.expectEqual(@as(i64, 41), r.s);
    try std.testing.expectEqual(@as(u8, 1), r.sched);
    try std.testing.expectEqualStrings("", r.role); // pre-attribution rows have no role
    try std.testing.expectEqual(@as(u64, 1), r.calls); // …and stood for exactly one turn
    try std.testing.expectEqual(@as(u64, 41_000), r.millis()); // falls back to `s`
}

test "per-role usage line: role/calls/ms parse, and ms wins over s" {
    const gpa = std.testing.allocator;
    const line = "{\"ts\":1784165341,\"role\":\"reflect\",\"model\":\"deepseek-v4-flash\",\"base\":\"api.deepseek.com\"," ++
        "\"calls\":3,\"in\":17061,\"out\":812,\"cached\":4096,\"ms\":9450,\"s\":9,\"sched\":0}";
    const parsed = try std.json.parseFromSlice(Row, gpa, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const r = parsed.value;
    try std.testing.expectEqualStrings("reflect", r.role);
    try std.testing.expectEqual(@as(u64, 3), r.calls);
    try std.testing.expectEqual(@as(u64, 4096), r.cached);
    try std.testing.expectEqual(@as(u64, 9450), r.millis()); // precise ms, not the rounded `s`
}

test "a trio's three rows aggregate per role AND per model without cross-billing" {
    // The bug this file exists to prevent: one turn, three labels, three models — the thinking and prompting
    // models' tokens must NOT land on the coding model's row.
    const rows = [_]Row{
        .{ .ts = 10, .role = "chat", .model = "kimi-k3", .base = "api.moonshot.ai", .calls = 1, .in = 30738, .out = 900, .ms = 12000 },
        .{ .ts = 11, .role = "reflect", .model = "deepseek-v4-flash", .base = "api.deepseek.com", .calls = 1, .in = 5687, .out = 210, .ms = 1500 },
        .{ .ts = 12, .role = "loop", .model = "openrouter/free", .base = "openrouter.ai", .calls = 2, .in = 17647, .out = 640, .ms = 3100 },
    };
    var per_role: [3]ModelAgg = .{ .{}, .{}, .{} };
    for (rows, 0..) |r, i| {
        per_role[i] = .{ .role = r.role, .model = r.model, .base = r.base };
        bump(&per_role[i], r);
    }
    try std.testing.expectEqual(@as(u64, 30738), per_role[0].in);
    try std.testing.expectEqual(@as(u64, 5687), per_role[1].in);
    try std.testing.expectEqual(@as(u64, 17647), per_role[2].in);
    try std.testing.expectEqual(@as(u64, 2), per_role[2].calls); // a row can stand for several calls
    try std.testing.expectEqual(@as(u64, 3100), per_role[2].ms);
    // nothing is lost or double-counted: the rows still sum to the turn's real spend
    var sum: u64 = 0;
    for (per_role) |m| sum += m.in;
    try std.testing.expectEqual(@as(u64, 30738 + 5687 + 17647), sum);
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

test "beginTurn clears a recycled thread's attribution buckets" {
    beginTurn(7, "m1", "https://api.deepseek.com/v1", false, 1000);
    try std.testing.expectEqual(@as(usize, 0), llm.roleCosts().len);
    try std.testing.expectEqual(@as(usize, 0), llm.callLog().len);
    endTurn();
}
