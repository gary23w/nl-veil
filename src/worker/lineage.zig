//! CROSS-RUN SWARM MEMORY — persistence keyed to a stable identity.
//!
//! Today a swarm's whole brain is `{run_dir}/mind.sqlite` (run.zig): born and destroyed with the run dir.
//! A long CONTINUOUS cast accumulates within its own life, but kill it and re-cast the same goal and the
//! second swarm starts from an empty brain — it re-learns everything the first one knew. That is why a
//! swarm doesn't visibly "get better over time": nothing carries across separate casts.
//!
//! A LINEAGE fixes that. When a cast declares `lineage: "<id>"`, its neuron-db is a STABLE per-user store
//! (`{userRoot}/_lineage/<slug>/mind.sqlite`) instead of a throwaway. Every later cast with the same id
//! opens the SAME brain, so knowledge, the self-authored playbook, the skill library, and the learned
//! trust ledger all COMPOUND run over run. This is exactly how a scheduled task already shares one memory
//! partition across its runs (chat/paths.zig, `sched:{tid}`) — lineage generalizes it to any cast.
//!
//! Why sharing the whole db is safe (not just the durable scopes): the run-local scopes are REPLACE-written
//! each run — establishPlan/consolidateState overwrite PLAN/STATE via Mem.replace, and the per-round write
//! ledger is file-based under run_dir, not in the db — so they don't accumulate cross-run garbage. The
//! scopes that SHOULD persist (knowledge, playbook/directives, skills, the global trust ledger) are exactly
//! the ones that do. Pack/corpus re-seeding stays idempotent because import runs with --dedup.
//!
//! Constraint for v1: one active cast per lineage at a time (two concurrent casts of the same id would
//! interleave their PLAN/STATE). The neuron-db write lock keeps the store itself consistent; the caster is
//! expected not to launch overlapping same-lineage runs.

const std = @import("std");

/// Sanitize a user-chosen lineage id into a filesystem-safe slug: lowercased, [a-z0-9-_] only, other runs
/// collapsed to '-', clipped. "default" when nothing survives (never an empty path segment).
pub fn slug(id: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pend_dash = false;
    for (id) |c| {
        const lc = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lc) or lc == '_') {
            if (pend_dash and n > 0 and n < buf.len) {
                buf[n] = '-';
                n += 1;
                pend_dash = false;
            }
            if (n < buf.len) {
                buf[n] = lc;
                n += 1;
            }
        } else {
            pend_dash = n > 0;
        }
    }
    const s = std.mem.trim(u8, buf[0..n], "-");
    return if (s.len == 0) "default" else s;
}

/// The per-user root a run_dir belongs to. A cast/chat run builds under ".../u{uid}/_chat/builds/{conv}"
/// and a scheduled run under ".../u{uid}/_sched/{tid}/runs/{stamp}" (chat/paths.zig), so the user root is
/// the prefix before that tail. Anything else (a bare cast/deploy dir) falls back to run_dir's parent — a
/// stable sibling location, just not user-partitioned. Slices borrow from `run_dir`.
pub fn userRootOf(run_dir: []const u8) []const u8 {
    if (std.mem.indexOf(u8, run_dir, "/_chat/")) |i| return run_dir[0..i];
    if (std.mem.indexOf(u8, run_dir, "/_sched/")) |i| return run_dir[0..i];
    // tolerate a trailing "/_chat" / "/_sched" with no further segments
    if (std.mem.endsWith(u8, run_dir, "/_chat")) return run_dir[0 .. run_dir.len - "/_chat".len];
    if (std.mem.endsWith(u8, run_dir, "/_sched")) return run_dir[0 .. run_dir.len - "/_sched".len];
    return std.fs.path.dirname(run_dir) orelse run_dir;
}

/// Resolve the persistent neuron-db path for `lineage_id`, creating its directory. null when the id is
/// empty (→ caller keeps the per-run `{run_dir}/mind.sqlite`). Caller frees a non-null result.
pub fn dbPath(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, lineage_id: []const u8) ?[]u8 {
    if (std.mem.trim(u8, lineage_id, " \t\r\n").len == 0) return null;
    var sb: [96]u8 = undefined;
    const s = slug(lineage_id, &sb);
    const root = userRootOf(run_dir);
    const dir = std.fmt.allocPrint(gpa, "{s}/_lineage/{s}", .{ root, s }) catch return null;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    return std.fmt.allocPrint(gpa, "{s}/mind.sqlite", .{dir}) catch null;
}

/// The db path of lineage `id` under a KNOWN user root ("{data}/u{uid}", as userRootOf returns it for every run
/// layout), for readers that must not create anything — the review API asks about a lineage, it never mints
/// one. Caller frees.
pub fn dbPathIn(gpa: std.mem.Allocator, user_root: []const u8, lineage_id: []const u8) ?[]u8 {
    if (std.mem.trim(u8, lineage_id, " \t\r\n").len == 0) return null;
    var sb: [96]u8 = undefined;
    return std.fmt.allocPrint(gpa, "{s}/_lineage/{s}/mind.sqlite", .{ user_root, slug(lineage_id, &sb) }) catch null;
}

/// HISTORY: one JSON line per finished cast of the lineage, beside its mind.sqlite. The store says what the lineage
/// KNOWS; this says how its casts DID, which is the only way to tell whether it gets better over time.
pub const HISTORY_FILE = "history.jsonl";

pub const Outcome = struct {
    t: i64, // unix seconds at DONE
    run: []const u8, // the run dir's last segment (a swarm id or a conversation id)
    reason: []const u8, // why it stopped (completed / time_budget / stopped ...)
    rounds: u32,
    best_pct: u32, // the engine's own best round score; not ground truth
    calls: u64,
    tok_in: u64,
    tok_out: u64,
    proposed: u32, // proposals the end-of-run judge and habit miner added to the quarantine
    inherited: bool, // the lineage store existed before this cast
};

/// `{dirname(db)}/history.jsonl`, or null. Pure.
pub fn historyPath(buf: []u8, db: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(db) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/" ++ HISTORY_FILE, .{dir}) catch null;
}

/// A string field safe to drop between JSON quotes: printable ASCII only, quote/backslash replaced. Pure.
fn safeField(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (n >= buf.len) break;
        buf[n] = if (c < 0x20 or c > 0x7e or c == '"' or c == '\\') '_' else c;
        n += 1;
    }
    return buf[0..n];
}

/// One history row, newline-terminated. Pure.
pub fn historyLine(buf: []u8, o: Outcome) []const u8 {
    var rb: [96]u8 = undefined;
    var sb: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{{\"t\":{d},\"run\":\"{s}\",\"reason\":\"{s}\",\"rounds\":{d},\"best_pct\":{d},\"calls\":{d},\"tok_in\":{d},\"tok_out\":{d},\"proposed\":{d},\"inherited\":{}}}\n", .{
        o.t, safeField(&rb, o.run), safeField(&sb, o.reason), o.rounds, o.best_pct, o.calls, o.tok_in, o.tok_out, o.proposed, o.inherited,
    }) catch "";
}

/// The newest `max` history rows as one JSON array (`[{...},{...}]`, oldest first). Lines that do not look like a
/// row are skipped, so a torn last line never breaks the array. Caller frees. Pure but for allocation.
pub fn historyArray(gpa: std.mem.Allocator, body: []const u8, max: usize) ![]u8 {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(gpa);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \r\t");
        if (l.len < 2 or l[0] != '{' or l[l.len - 1] != '}') continue;
        try rows.append(gpa, l);
    }
    const from = if (rows.items.len > max) rows.items.len - max else 0;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '[');
    for (rows.items[from..], 0..) |r, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, r);
    }
    try out.append(gpa, ']');
    return out.toOwnedSlice(gpa);
}

/// Does this lineage store already exist (i.e. a prior cast populated it)? Lets the engine tell a mind
/// "you INHERIT the memory of N prior runs on this assignment" vs "you are the first run".
pub fn exists(io: std.Io, gpa: std.mem.Allocator, db: []const u8) bool {
    _ = gpa;
    return if (std.Io.Dir.cwd().statFile(io, db, .{})) |st| st.size > 0 else |_| false;
}

// ------------------------------------------------------------------------------------------- tests

const t = std.testing;

test "history: a row is one JSON object per line, hostile strings cannot break it, and the array keeps the newest" {
    const gpa = t.allocator;
    var pb: [256]u8 = undefined;
    try t.expectEqualStrings("C:/x/data/u1/_lineage/p/history.jsonl", historyPath(&pb, "C:/x/data/u1/_lineage/p/mind.sqlite").?);
    var b: [512]u8 = undefined;
    const line = historyLine(&b, .{ .t = 7, .run = "conv\"x\\y", .reason = "completed\n", .rounds = 3, .best_pct = 95, .calls = 40, .tok_in = 1000, .tok_out = 50, .proposed = 2, .inherited = true });
    try t.expect(std.mem.endsWith(u8, line, "}\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trimEnd(u8, line, "\n"), .{});
    defer parsed.deinit();
    try t.expectEqualStrings("conv_x_y", parsed.value.object.get("run").?.string);
    try t.expectEqual(@as(i64, 95), parsed.value.object.get("best_pct").?.integer);
    try t.expect(parsed.value.object.get("inherited").?.bool);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    var i: u32 = 0;
    while (i < 5) : (i += 1) try body.appendSlice(gpa, historyLine(&b, .{ .t = i, .run = "r", .reason = "done", .rounds = i, .best_pct = i, .calls = 0, .tok_in = 0, .tok_out = 0, .proposed = 0, .inherited = i > 0 }));
    try body.appendSlice(gpa, "{\"t\":99,\"run\""); // a torn last line
    const arr = try historyArray(gpa, body.items, 3);
    defer gpa.free(arr);
    const pa = try std.json.parseFromSlice(std.json.Value, gpa, arr, .{});
    defer pa.deinit();
    try t.expectEqual(@as(usize, 3), pa.value.array.items.len);
    try t.expectEqual(@as(i64, 2), pa.value.array.items[0].object.get("t").?.integer); // oldest of the newest 3
    const empty = try historyArray(gpa, "", 10);
    defer gpa.free(empty);
    try t.expectEqualStrings("[]", empty);
}

test "slug sanitizes to a safe path segment" {
    var b: [96]u8 = undefined;
    try t.expectEqualStrings("my-webapp", slug("My WebApp!", &b));
    try t.expectEqualStrings("acme_billing-v2", slug("  acme_billing / v2  ", &b));
    try t.expectEqualStrings("default", slug("///", &b));
    try t.expectEqualStrings("a-b-c", slug("a.b.c", &b));
}

test "userRootOf peels the chat/sched build tail" {
    try t.expectEqualStrings("data/u1", userRootOf("data/u1/_chat/builds/c42"));
    try t.expectEqualStrings("C:/x/data/u7", userRootOf("C:/x/data/u7/_sched/daily/runs/07221200"));
    try t.expectEqualStrings("data/u3", userRootOf("data/u3/_chat"));
    // an unrecognized layout falls back to the parent dir
    try t.expectEqualStrings("data/swarms", userRootOf("data/swarms/run-9"));
}

test "dbPath is stable across runs of the same lineage, empty id opts out" {
    const gpa = t.allocator;
    const io = t.io;
    // two different run dirs, same user + lineage → the SAME persistent db (that is the whole point)
    const a = dbPath(gpa, io, "C:/x/data/u1/_chat/builds/conv-A", "my proj").?;
    defer gpa.free(a);
    const b = dbPath(gpa, io, "C:/x/data/u1/_chat/builds/conv-B", "my proj").?;
    defer gpa.free(b);
    try t.expectEqualStrings(a, b);
    try t.expect(std.mem.endsWith(u8, a, "/_lineage/my-proj/mind.sqlite"));
    try t.expect(std.mem.indexOf(u8, a, "C:/x/data/u1/") != null);
    // no lineage → null → caller keeps the per-run brain
    try t.expect(dbPath(gpa, io, "C:/x/data/u1/_chat/builds/conv-A", "") == null);
    try t.expect(dbPath(gpa, io, "C:/x/data/u1/_chat/builds/conv-A", "   ") == null);
    // the reader's path for the same lineage is the same file, and it creates nothing
    const c = dbPathIn(gpa, userRootOf("C:/x/data/u1/_chat/builds/conv-A"), "My Proj").?;
    defer gpa.free(c);
    try t.expectEqualStrings(a, c);
    try t.expect(dbPathIn(gpa, "C:/x/data/u1", " ") == null);
}
