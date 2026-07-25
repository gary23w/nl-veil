//! neurondb.zig — a minimal client for the chat's HIPPOCAMPUS. Spawns the `neuron` CLI (the same binary the
//! swarm minds use) against a chat-local sqlite db to OBSERVE conversation turns + cast findings as neurons and
//! ASSOC-recall the relevant ones into the next prompt. Everything degrades to a silent no-op if the binary or
//! db path is unavailable, so the chat behaves EXACTLY as before whenever neuron-db isn't present or errors.

const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");

pub const Db = struct {
    gpa: std.mem.Allocator,
    io: Io,
    bin: []const u8 = "", // path to the neuron binary ("" = disabled → all ops no-op)
    db: []const u8 = "", //  path to the chat sqlite ("" = disabled)

    fn run(self: Db, args: []const []const u8) ?[]u8 {
        log.trace("neuron.Db.run args0={s} db={s}", .{ if (args.len > 0) args[0] else "", self.db });
        if (self.bin.len == 0 or self.db.len == 0) return null;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        argv.appendSlice(self.gpa, &.{ self.bin, "--db", self.db }) catch return null;
        argv.appendSlice(self.gpa, args) catch return null;
        const r = std.process.run(self.gpa, self.io, .{ .argv = argv.items, .stdout_limit = .limited(256 << 10) }) catch return null;
        self.gpa.free(r.stderr);
        if (r.term != .exited) {
            self.gpa.free(r.stdout);
            return null;
        }
        return r.stdout; // caller frees
    }

    pub fn enabled(self: Db) bool {
        return self.bin.len > 0 and self.db.len > 0;
    }

    /// Store one fact under `scope`. Trimmed + capped so facts stay atomic; no-op on any failure.
    pub fn observe(self: Db, scope: []const u8, text: []const u8) void {
        log.trace("neuron.Db.observe scope={s} text_len={d}", .{ scope, text.len });
        const t = std.mem.trim(u8, text, " \r\n\t");
        if (t.len < 3) return;
        if (self.run(&.{ "observe", scope, t[0..@min(t.len, 1400)] })) |o| self.gpa.free(o);
    }

    /// TRUST-WEIGHTED spreading-activation recall: the facts relevant to `query`, ranked by relevance × the
    /// learned per-tag-class trust (the `--trust` floor), so sources that proved reliable out-rank noise. Copied
    /// into `out`; empty slice on miss. Belief → recall. Degrades to plain assoc on an older binary (no-op on fail).
    pub fn recall(self: Db, scope: []const u8, query: []const u8, out: []u8) []const u8 {
        log.trace("neuron.Db.recall scope={s} query_len={d}", .{ scope, query.len });
        const q = std.mem.trim(u8, query, " \r\n\t");
        if (q.len < 3) return out[0..0];
        const o = self.run(&.{ "--trust", "assoc", scope, q[0..@min(q.len, 400)] }) orelse return out[0..0];
        defer self.gpa.free(o);
        const trimmed = std.mem.trim(u8, o, " \r\n\t");
        // neuron prints "(the hive knows nothing…)" style lines on a miss — treat a short/parenthetical reply
        // as empty so we never inject noise.
        if (trimmed.len < 24 or trimmed[0] == '(') return out[0..0];
        const n = @min(trimmed.len, out.len);
        @memcpy(out[0..n], trimmed[0..n]);
        return out[0..n];
    }

    /// HEBBIAN plasticity (learning → plasticity): strengthen the facts under `scope` whose key matches `topic`
    /// and fade the competitors, so a topic the chat engaged with successfully out-ranks the alternatives in
    /// later recall — the chat's memory LEARNS from outcomes instead of only accumulating. No-op on any failure.
    pub fn reinforce(self: Db, scope: []const u8, topic: []const u8, feeling: []const u8) void {
        log.trace("neuron.Db.reinforce scope={s} topic={s} feeling={s}", .{ scope, topic, feeling });
        const t = std.mem.trim(u8, topic, " \r\n\t");
        if (t.len < 3) return;
        const f = if (feeling.len > 0) feeling else "useful";
        if (self.run(&.{ "reinforce", scope, t[0..@min(t.len, 200)], f })) |o| self.gpa.free(o);
    }

    /// STRENGTHEN-ONLY plasticity (the positive mirror of forget): bump the strength of the facts under `scope`
    /// whose text CONTAINS `match` (substring), so an outcome-confirmed fact out-ranks its neighbours in later
    /// recall. Unlike reinforce()/note_stance it NEVER mints a new fact and never rewrites text — outcome
    /// feedback keyed on arbitrary text (a recalled lesson, a user prompt) can only re-rank what was actually
    /// learned, never invent a memory from its own key. No-op on any failure.
    pub fn strengthen(self: Db, scope: []const u8, match: []const u8) void {
        log.trace("neuron.Db.strengthen scope={s} match_len={d}", .{ scope, match.len });
        const m = std.mem.trim(u8, match, " \r\n\t");
        if (m.len < 3) return; // too short to identify a fact — never strengthen on a stopword-length key
        var cut: usize = @min(m.len, 300);
        while (cut > 0 and cut < m.len and (m[cut] & 0xC0) == 0x80) cut -= 1; // never split a codepoint — a half-char key matches nothing
        if (self.run(&.{ "strengthen", scope, m[0..cut] })) |o| self.gpa.free(o);
    }

    /// Drop the facts under `scope` that contain `match` (substring). Used to delete one durable memory when the
    /// user (or the AI, via FORGET:) retires a stale key/preference. No-op on any failure or empty match.
    pub fn forget(self: Db, scope: []const u8, match: []const u8) void {
        log.trace("neuron.Db.forget scope={s} match={s}", .{ scope, match });
        const m = std.mem.trim(u8, match, " \r\n\t");
        if (m.len < 3) return; // never pass an empty match — that would wipe the whole scope
        if (self.run(&.{ "forget", scope, m[0..@min(m.len, 120)] })) |o| self.gpa.free(o);
    }

    /// Dump every fact in `scope` (the CLI's `export` — "# scope: X" header + one fact text per line,
    /// insertion order, oldest first). Caller frees. Null when disabled/empty/error — silent no-op.
    pub fn dump(self: Db, scope: []const u8) ?[]u8 {
        log.trace("neuron.Db.dump scope={s}", .{scope});
        if (scope.len == 0) return null;
        return self.run(&.{ "export", scope });
    }

    pub const ScopeStats = struct { facts: u64 = 0, created_ms: u64 = 0, updated_ms: u64 = 0 };

    /// Parse `stats <scope>` ("facts: N ... created: MS updated: MS"). Null on any failure.
    pub fn statsScope(self: Db, scope: []const u8) ?ScopeStats {
        log.trace("neuron.Db.statsScope scope={s}", .{scope});
        if (scope.len == 0) return null;
        const o = self.run(&.{ "stats", scope }) orelse return null;
        defer self.gpa.free(o);
        var st = ScopeStats{};
        var it = std.mem.tokenizeAny(u8, o, " \r\n\t");
        while (it.next()) |tok| {
            const val = if (std.mem.eql(u8, tok, "facts:") or std.mem.eql(u8, tok, "created:") or std.mem.eql(u8, tok, "updated:"))
                (it.next() orelse return st)
            else
                continue;
            const n = std.fmt.parseInt(u64, val, 10) catch continue;
            if (tok[0] == 'f') st.facts = n else if (tok[0] == 'c') st.created_ms = n else st.updated_ms = n;
        }
        return st;
    }

    /// Wipe a WHOLE scope. Deliberately separate from forget(): the empty-match guard there protects
    /// normal deletion; this exists ONLY for the curator's export-then-forget archival, and callers must
    /// have verified the export file landed on disk first. Never called on user-facing scopes.
    pub fn forgetAll(self: Db, scope: []const u8) void {
        log.trace("neuron.Db.forgetAll scope={s}", .{scope});
        if (scope.len == 0) return;
        if (self.run(&.{ "forget", scope })) |o| self.gpa.free(o);
    }

    /// Relational multi-hop CHAIN traversal (reasoning → chain): walk `start` --relation--> … over the fact
    /// graph, recalling at each hop. Deterministic, no model round-trip — how a caller reasons over a
    /// causal/dependency chain instead of re-deriving it. Returns the endpoint value into `out`; empty on a break.
    pub fn chain(self: Db, scope: []const u8, start: []const u8, relation: []const u8, out: []u8) []const u8 {
        log.trace("neuron.Db.chain scope={s} start={s} relation={s}", .{ scope, start, relation });
        if (start.len == 0 or relation.len == 0) return out[0..0];
        const o = self.run(&.{ "chain", scope, start, relation }) orelse return out[0..0];
        defer self.gpa.free(o);
        const trimmed = std.mem.trim(u8, o, " \r\n\t");
        if (trimmed.len == 0 or trimmed[0] == '(') return out[0..0]; // "(chain broke after …)" = no path
        const n = @min(trimmed.len, out.len);
        @memcpy(out[0..n], trimmed[0..n]);
        return out[0..n];
    }
};

/// Locate the neuron binary near the app (cwd is the nl-veil home when launched normally). "" if not found;
/// caller owns the returned slice.
pub fn findBin(gpa: std.mem.Allocator, io: Io) []const u8 {
    log.trace("neuron.findBin", .{});
    const cands = [_][]const u8{ "bin/neuron.exe", "bin/neuron", "neuron.exe", "./neuron.exe", "../bin/neuron.exe", "../bin/neuron" };
    for (cands) |c| {
        if (Io.Dir.cwd().statFile(io, c, .{})) |_| {
            return gpa.dupe(u8, c) catch "";
        } else |_| {}
    }
    return "";
}

// ---- tests ---------------------------------------------------------------------------------------------
//
// The contract this file exists for is FAIL-OPEN: with the binary or the db missing, unreadable or broken,
// the chat must behave EXACTLY as it did before neuron-db existed. Each test below is one way of asking
// "can the caller tell that the store failed?" — the answer has to be no, in every direction.
//
// std.testing.allocator is the second assertion in all of them: run() builds an argv and takes ownership of
// a stdout buffer on every call, so a degraded path that forgot to free shows up here as a leak instead of
// as slow growth over a long chat session.

const TMP_ROOT = "zig-neuron-tmp";

test "a bridge with no binary and no db is a silent no-op in every direction" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const db = Db{ .gpa = std.testing.allocator, .io = threaded.io() };
    try std.testing.expect(!db.enabled());
    var out: [256]u8 = undefined;
    // reads degrade to "nothing recalled" — not an error the chat has to handle, not a partial answer
    try std.testing.expectEqual(@as(usize, 0), db.recall("chat:1", "a real query", &out).len);
    try std.testing.expectEqual(@as(usize, 0), db.chain("chat:1", "start", "causes", &out).len);
    try std.testing.expect(db.dump("chat:1") == null);
    try std.testing.expect(db.statsScope("chat:1") == null);
    // and writes return normally, having done nothing
    db.observe("chat:1", "a fact long enough to clear the guard");
    db.reinforce("chat:1", "a topic", "useful");
    db.strengthen("chat:1", "a fact long enough to clear the guard");
    db.forget("chat:1", "a match key");
    db.forgetAll("chat:1");
}

test "an unreachable store degrades exactly like a disabled one — the caller never sees the failure" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = @import("llm.zig").osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    Io.Dir.cwd().deleteTree(io, TMP_ROOT) catch {}; // a previous crash may have left it behind
    defer Io.Dir.cwd().deleteTree(io, TMP_ROOT) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, TMP_ROOT, .default_dir) catch {};
    // enabled() says YES here — both paths are configured — but the spawn cannot succeed. This is the live
    // failure mode: neuron.exe deleted, moved by an install, or (this repo has form) Defender-quarantined
    // mid-session. The bridge must not turn that into a chat that errors or stops answering.
    const db = Db{
        .gpa = gpa,
        .io = io,
        .bin = TMP_ROOT ++ "/no-such-neuron.exe",
        .db = TMP_ROOT ++ "/mem.sqlite",
    };
    try std.testing.expect(db.enabled());
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), db.recall("chat:1", "a real query", &out).len);
    try std.testing.expectEqual(@as(usize, 0), db.chain("chat:1", "start", "causes", &out).len);
    try std.testing.expect(db.dump("chat:1") == null);
    try std.testing.expect(db.statsScope("chat:1") == null);
    db.observe("chat:1", "a fact long enough to clear the guard");
    db.reinforce("chat:1", "a topic", "useful");
    db.strengthen("chat:1", "a fact long enough to clear the guard");
    db.forget("chat:1", "a match key");
    db.forgetAll("chat:1");
}

test "a key too short to identify a fact never becomes a query" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = @import("llm.zig").osEnviron() });
    defer threaded.deinit();
    const db = Db{ .gpa = gpa, .io = threaded.io(), .bin = "no-such-neuron.exe", .db = "no-such.sqlite" };
    var out: [64]u8 = undefined;
    // a stopword-length key would match half the scope, so the readers refuse it before it is a query…
    const short = db.recall("chat:1", "ab", &out);
    try std.testing.expectEqual(@as(usize, 0), short.len);
    // …and the empty answer is a slice OF the caller's buffer, so `out[0..n]` stays valid for the caller
    try std.testing.expectEqual(@as([*]const u8, &out), short.ptr);
    try std.testing.expectEqual(@as(usize, 0), db.recall("chat:1", "   \r\n ", &out).len);
    // a chain needs both ends: half a traversal is not a shorter traversal, it is no traversal
    try std.testing.expectEqual(@as(usize, 0), db.chain("chat:1", "", "causes", &out).len);
    try std.testing.expectEqual(@as(usize, 0), db.chain("chat:1", "start", "", &out).len);
    // an empty scope is never a wildcard
    try std.testing.expect(db.dump("") == null);
    try std.testing.expect(db.statsScope("") == null);
    db.forgetAll("");
}

test "findBin hands back a slice the caller owns, found or not, and never names a path that is not there" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bin = findBin(gpa, io);
    defer gpa.free(bin); // "" is a zero-length free (a no-op), so callers never have to branch on the miss
    if (bin.len > 0) {
        // the probe is a real statFile, not a guess about the layout — whatever it named must be there
        _ = Io.Dir.cwd().statFile(io, bin, .{}) catch return error.TestUnexpectedResult;
    }
}

test "a real store round-trips, and the blank-match guard holds against its own counterfactual" {
    const gpa = std.testing.allocator;
    // The desk's own Io carries the process environ (main.zig), and so must this one: a child spawned into
    // an empty environment on Windows comes up with no SystemRoot/TEMP and fails INSIDE a `catch {}`, which
    // would leave this test asserting against a store that was never written (TESTING.md, 0015).
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = @import("llm.zig").osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = findBin(gpa, io);
    defer gpa.free(bin);
    if (bin.len == 0) return error.SkipZigTest; // no neuron CLI in this checkout — a skip is honest

    Io.Dir.cwd().deleteTree(io, TMP_ROOT) catch {};
    defer Io.Dir.cwd().deleteTree(io, TMP_ROOT) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, TMP_ROOT, .default_dir) catch {};
    const db = Db{ .gpa = gpa, .io = io, .bin = bin, .db = TMP_ROOT ++ "/mem.sqlite" };
    const scope = "desk_neuron_bridge_test";

    // Probe with a call that only the SPAWN can fail: a CLI that ran always prints its counters, so a null
    // here means the binary could not execute at all. That separates "the dependency is unusable on this
    // machine" (skip) from "the bridge broke its contract" (fail) — everything below is the latter.
    if (db.statsScope(scope) == null) return error.SkipZigTest;

    const fact = "the desk neuron bridge round trip fact about zigzagbadger telemetry";
    db.observe(scope, fact);
    {   // observe → the fact is IN the store: a write that silently did nothing looks identical from the
        // caller's side, so the only honest probe is reading it back out.
        const dumped = db.dump(scope) orelse return error.TestUnexpectedResult;
        defer gpa.free(dumped);
        try std.testing.expect(std.mem.indexOf(u8, dumped, "zigzagbadger") != null);
    }
    const st = db.statsScope(scope) orelse return error.TestUnexpectedResult;
    try std.testing.expect(st.facts >= 1);
    try std.testing.expect(st.created_ms > 0 and st.updated_ms >= st.created_ms);

    var out: [4096]u8 = undefined;
    const recalled = db.recall(scope, "zigzagbadger telemetry", &out);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "zigzagbadger") != null);

    // THE GUARD, against its own counterfactual. forget() with a blank match must never reach the CLI,
    // because `forget <scope>` with no match drops the WHOLE scope — which is exactly what the deliberate
    // forgetAll() does four lines down, on the same binary, the same db and the same scope.
    db.forget(scope, "  \n\t ");
    {
        const after_blank = db.dump(scope) orelse return error.TestUnexpectedResult;
        defer gpa.free(after_blank);
        try std.testing.expect(std.mem.indexOf(u8, after_blank, "zigzagbadger") != null);
    }
    db.forgetAll(scope);
    {
        const after_wipe = db.dump(scope) orelse return error.TestUnexpectedResult;
        defer gpa.free(after_wipe);
        try std.testing.expect(std.mem.indexOf(u8, after_wipe, "zigzagbadger") == null);
    }
}
