//! vcs.zig — swarm micro version-control: serialized, corruption-safe commits so multiple minds can edit ONE
//! shared file.

const std = @import("std");
const bufedit = @import("bufedit.zig");

const Hash = [16]u8;

fn hash16(bytes: []const u8) Hash {
    var h: Hash = undefined;
    std.mem.writeInt(u64, h[0..8], std.hash.XxHash64.hash(0x9E3779B97F4A7C15, bytes), .little);
    std.mem.writeInt(u64, h[8..16], std.hash.XxHash64.hash(0xC2B2AE3D27D4EB4F, bytes), .little);
    return h;
}
fn hex32(h: Hash) [32]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("out of memory");
}

// guidance FIRST, bufedit's reject LAST: on a stale anchor the reject now ends with the current file's
// closest region ("The file NOW reads ..."), and the copyable lines must be the final thing the mind sees —
// the old shape buried them mid-sentence and cost a whole read_file turn per lost repair attempt (observed
// live, openai_splash_test_4 r4-6 on digest/__init__.py and digest/rank.py).
fn conflictMsg(gpa: std.mem.Allocator, reject: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "edit conflict: the file changed since you read it (a teammate edited the same region) — re-emit your SEARCH/REPLACE against the CURRENT lines. {s}", .{reject}) catch dupe(gpa, "edit conflict — read_file the file again and re-emit against the current lines.");
}

pub const Decision = union(enum) {
    write: struct { bytes: []u8, rebased: bool }, // owned bytes to land; rebased = a teammate had advanced HEAD
    conflict: []u8, // owned message
};

/// PURE merge core (no I/O): given current HEAD bytes `cur`, the `base` the mind read, and the mind's `ops`, decide
/// the merged bytes to write or an actionable conflict. Re-applies ops onto HEAD, so disjoint edits merge and a
/// changed target rejects. `rebased` is true when a teammate advanced HEAD under the mind (base != cur).
pub fn mergeDecision(gpa: std.mem.Allocator, cur: []const u8, base: []const u8, ops: []const bufedit.EditOp) Decision {
    const rebased = base.len > 0 and !std.mem.eql(u8, base, cur);
    const applied = bufedit.apply(gpa, cur, ops);
    if (!applied.ok) {
        defer gpa.free(applied.reject);
        return .{ .conflict = conflictMsg(gpa, applied.reject) };
    }
    if (applied.loci.len > 0) gpa.free(applied.loci);
    return .{ .write = .{ .bytes = applied.bytes, .rebased = rebased } };
}

pub const Result = union(enum) {
    committed: struct { len: usize, seq: u32, rebased: bool },
    conflict: []u8, // owned
    failed: []u8, // owned
};

/// Land `data` at `full` via a same-dir temp + atomic rename (never a byte-copy). false on any error, prior intact.
fn writeAtomic(io: std.Io, full: []const u8, data: []const u8) bool {
    var af = std.Io.Dir.cwd().createFileAtomic(io, full, .{ .replace = true, .make_path = true }) catch return false;
    defer af.deinit(io);
    af.file.writeStreamingAll(io, data) catch return false;
    af.file.sync(io) catch {};
    af.replace(io) catch return false;
    return true;
}

fn readSeq(io: std.Io, gpa: std.mem.Allocator, vcs_dir: []const u8, rk: []const u8) u32 {
    const p = std.fmt.allocPrint(gpa, "{s}/refs/{s}.head", .{ vcs_dir, rk }) catch return 0;
    defer gpa.free(p);
    const body = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 10)) catch return 0;
    defer gpa.free(body);
    var it = std.mem.tokenizeAny(u8, body, " \t\r\n");
    _ = it.next() orelse return 0; // head hash (stored for observability)
    const seqs = it.next() orelse return 0;
    return std.fmt.parseInt(u32, seqs, 10) catch 0;
}

fn writeRef(io: std.Io, gpa: std.mem.Allocator, vcs_dir: []const u8, rk: []const u8, h: Hash, seq: u32, npath: []const u8) void {
    const p = std.fmt.allocPrint(gpa, "{s}/refs/{s}.head", .{ vcs_dir, rk }) catch return;
    defer gpa.free(p);
    const line = std.fmt.allocPrint(gpa, "{s} {d} {s}\n", .{ hex32(h), seq, npath }) catch return;
    defer gpa.free(line);
    _ = writeAtomic(io, p, line);
}

fn writeObject(io: std.Io, gpa: std.mem.Allocator, vcs_dir: []const u8, h: Hash, bytes: []const u8) void {
    const p = std.fmt.allocPrint(gpa, "{s}/objects/{s}", .{ vcs_dir, hex32(h) }) catch return;
    defer gpa.free(p);
    _ = writeAtomic(io, p, bytes); // content-addressed & immutable — rewriting identical content is idempotent
}

fn appendLine(io: std.Io, gpa: std.mem.Allocator, path: []const u8, line: []const u8, cap: usize) void {
    const prior = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(cap)) catch &[_]u8{};
    defer if (prior.len > 0) gpa.free(prior);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, prior) catch {};
    buf.appendSlice(gpa, line) catch {};
    _ = writeAtomic(io, path, buf.items);
}

/// Optional pre-commit content gate, called IN-LOCK with (HEAD, candidate) right before the write. A non-null
/// return is an owned reject message: the commit is abandoned and the file stays untouched. This is how the
/// language gates (py-compile, duplicate-definition) reach the CONCURRENT path — without it every team>1 run
/// bypassed edit_file's own gate entirely (the VCS branch returned before the gate ran), which is how a
/// SEARCH/REPLACE spliced a full second copy of users.py into the file with no rejection.
pub const Validator = struct {
    ctx: *anyopaque,
    check: *const fn (vctx: *anyopaque, head: []const u8, candidate: []const u8) ?[]u8,
};

/// Commit a mind's edit ops to `full_workpath` under `fmtx`. See file header for the correctness argument. Caller
/// owns any returned message; on `committed` the caller builds its own success string.
pub fn commitEdit(
    io: std.Io,
    gpa: std.mem.Allocator,
    fmtx: *std.Io.Mutex,
    run_dir: []const u8,
    npath: []const u8,
    full_workpath: []const u8,
    ops: []const bufedit.EditOp,
    base: []const u8,
    mind: []const u8,
    validator: ?Validator,
) Result {
    fmtx.lockUncancelable(io);
    defer fmtx.unlock(io);

    // HEAD = the file on disk, read IN-LOCK (authoritative; also catches an external --embed edit). Cap matches
    // editFile's own read cap so nothing over 1 MiB reaches this path. A FAILED read is not an empty file:
    // the caller proved the file exists (its own unlocked read succeeded), so treating a transient
    // sharing-violation as "" would merge the ops against nothing and REPLACE the whole file with a fragment.
    var head_unreadable = false;
    const cur = std.Io.Dir.cwd().readFileAlloc(io, full_workpath, gpa, .limited(1 << 20)) catch blk: {
        head_unreadable = true;
        break :blk @constCast("");
    };
    defer if (cur.len > 0) gpa.free(cur);
    if (head_unreadable and base.len > 0)
        return .{ .failed = dupe(gpa, "could not read the file's current state (transient lock?) — re-issue the edit") };

    const dec = mergeDecision(gpa, cur, base, ops);
    switch (dec) {
        .conflict => |m| return .{ .conflict = m },
        .write => |w| {
            defer gpa.free(w.bytes);
            if (validator) |v| if (v.check(v.ctx, cur, w.bytes)) |msg| return .{ .failed = msg };
            if (!writeAtomic(io, full_workpath, w.bytes))
                return .{ .failed = dupe(gpa, "could not write the edited file (locked by another process?)") };

            // History + manifest: best-effort, all under the held lock. A failure here never corrupts the work
            // file (already landed atomically) — it only loses a history point.
            const vcs_dir = std.fmt.allocPrint(gpa, "{s}/.vcs", .{run_dir}) catch return .{ .committed = .{ .len = w.bytes.len, .seq = 0, .rebased = w.rebased } };
            defer gpa.free(vcs_dir);
            const rk = hex32(hash16(npath));
            const h = hash16(w.bytes);
            const seq = readSeq(io, gpa, vcs_dir, &rk) + 1;
            writeObject(io, gpa, vcs_dir, h, w.bytes);
            writeRef(io, gpa, vcs_dir, &rk, h, seq, npath);
            const logp = std.fmt.allocPrint(gpa, "{s}/log/{s}.log", .{ vcs_dir, &rk }) catch "";
            defer if (logp.len > 0) gpa.free(logp);
            if (logp.len > 0) {
                const ll = std.fmt.allocPrint(gpa, "{d}\t{s}\t{s}\t{s}\n", .{ seq, hex32(h), mind, if (w.rebased) "merge" else "edit" }) catch "";
                defer if (ll.len > 0) gpa.free(ll);
                if (ll.len > 0) appendLine(io, gpa, logp, ll, 256 << 10);
            }
            const manp = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch "";
            defer if (manp.len > 0) gpa.free(manp);
            if (manp.len > 0) {
                const ml = std.fmt.allocPrint(gpa, "{s}|{d}\n", .{ npath, w.bytes.len }) catch "";
                defer if (ml.len > 0) gpa.free(ml);
                if (ml.len > 0) appendLine(io, gpa, manp, ml, 64 << 10);
            }
            return .{ .committed = .{ .len = w.bytes.len, .seq = seq, .rebased = w.rebased } };
        },
    }
}

// ---------------------------------------------------------------------------------------------------- tests
test "mergeDecision: fast-forward when nobody else changed HEAD" {
    const gpa = std.testing.allocator;
    const base = "a\ntarget\nb\n";
    const dec = mergeDecision(gpa, base, base, &.{.{ .kind = .replace, .anchor = "target", .text = "TARGET" }});
    switch (dec) {
        .write => |w| {
            defer gpa.free(w.bytes);
            try std.testing.expect(!w.rebased);
            try std.testing.expectEqualStrings("a\nTARGET\nb\n", w.bytes);
        },
        .conflict => |m| {
            defer gpa.free(m);
            return error.UnexpectedConflict;
        },
    }
}

test "mergeDecision: auto-merges a disjoint edit onto a HEAD a teammate advanced" {
    const gpa = std.testing.allocator;
    const base = "fn a() 1\nfn b() 2\n";
    const cur = "fn a() 99\nfn b() 2\n"; // teammate changed a; my target (b) is intact
    const dec = mergeDecision(gpa, cur, base, &.{.{ .kind = .replace, .anchor = "fn b() 2", .text = "fn b() 3" }});
    switch (dec) {
        .write => |w| {
            defer gpa.free(w.bytes);
            try std.testing.expect(w.rebased);
            try std.testing.expectEqualStrings("fn a() 99\nfn b() 3\n", w.bytes); // BOTH changes present
        },
        .conflict => |m| {
            defer gpa.free(m);
            return error.UnexpectedConflict;
        },
    }
}

test "mergeDecision: conflict when a teammate changed the same region (anchor gone)" {
    const gpa = std.testing.allocator;
    const base = "x\nold line\ny\n";
    const cur = "x\nteammate rewrote this\ny\n"; // my anchor is no longer present on HEAD
    const dec = mergeDecision(gpa, cur, base, &.{.{ .kind = .replace, .anchor = "old line", .text = "my change" }});
    switch (dec) {
        .conflict => |m| {
            defer gpa.free(m);
            try std.testing.expect(std.mem.indexOf(u8, m, "conflict") != null);
            try std.testing.expect(std.mem.indexOf(u8, m, "re-emit") != null); // guidance leads ...
            try std.testing.expect(std.mem.indexOf(u8, m, "read_file") != null); // ... bufedit's hint (region gone) ends the message
        },
        .write => |w| {
            defer gpa.free(w.bytes);
            return error.ExpectedConflict;
        },
    }
}

test "commitEdit: two minds merge disjoint edits, a third with a stale base conflicts (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-vcs-it-tmp"; // run_dir, relative to cwd
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var fmtx: std.Io.Mutex = .init;
    const full = root ++ "/work/app.txt";
    const npath = "app.txt";
    const base = "fn a() 1\nfn b() 2\n";
    try std.testing.expect(writeAtomic(io, full, base)); // seed HEAD

    // mind A edits fn a (base == HEAD -> fast-forward)
    {
        const r = commitEdit(io, gpa, &fmtx, root, npath, full, &.{.{ .kind = .replace, .anchor = "fn a() 1", .text = "fn a() 11" }}, base, "A", null);
        try std.testing.expect(r == .committed);
    }
    // mind B edits fn b with a STALE base (never saw A's commit) -> must rebase onto A and merge
    {
        const r = commitEdit(io, gpa, &fmtx, root, npath, full, &.{.{ .kind = .replace, .anchor = "fn b() 2", .text = "fn b() 22" }}, base, "B", null);
        switch (r) {
            .committed => |c| try std.testing.expect(c.rebased),
            .conflict => |m| {
                gpa.free(m);
                return error.BUnexpectedConflict;
            },
            .failed => |m| {
                gpa.free(m);
                return error.BFailed;
            },
        }
    }
    {
        const after = try std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20));
        defer gpa.free(after);
        try std.testing.expectEqualStrings("fn a() 11\nfn b() 22\n", after); // BOTH landed
    }
    // mind C edits fn a's ORIGINAL line (A already changed it) with a stale base -> conflict, file untouched
    {
        const r = commitEdit(io, gpa, &fmtx, root, npath, full, &.{.{ .kind = .replace, .anchor = "fn a() 1", .text = "fn a() 999" }}, base, "C", null);
        switch (r) {
            .conflict => |m| {
                defer gpa.free(m);
                // the stale-anchor reject must carry the CURRENT line so C can re-anchor in the SAME turn
                try std.testing.expect(std.mem.indexOf(u8, m, "fn a() 11") != null);
            },
            .committed => return error.CExpectedConflict,
            .failed => |m| {
                gpa.free(m);
                return error.CFailed;
            },
        }
    }
    {
        const after = try std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20));
        defer gpa.free(after);
        try std.testing.expectEqualStrings("fn a() 11\nfn b() 22\n", after); // conflict left HEAD intact
    }
    // history advanced exactly twice (A, B); C did not commit
    const vcs_dir = root ++ "/.vcs";
    const rk = hex32(hash16(npath));
    try std.testing.expect(readSeq(io, gpa, vcs_dir, &rk) == 2);
}

test "commitEdit: the pre-commit validator rejects IN-LOCK and HEAD stays untouched (the gate the VCS path used to bypass)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-vcs-gate-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var fmtx: std.Io.Mutex = .init;
    const full = root ++ "/work/mod.py";
    const base = "def a():\n    return 1\n";
    try std.testing.expect(writeAtomic(io, full, base));

    const G = struct {
        var saw_head: bool = false;
        fn reject(vctx: *anyopaque, head: []const u8, candidate: []const u8) ?[]u8 {
            _ = vctx;
            saw_head = std.mem.indexOf(u8, head, "def a()") != null and std.mem.indexOf(u8, candidate, "# edited") != null;
            return std.testing.allocator.dupe(u8, "edit REJECTED — gate says no") catch null;
        }
        fn accept(vctx: *anyopaque, head: []const u8, candidate: []const u8) ?[]u8 {
            _ = vctx;
            _ = head;
            _ = candidate;
            return null;
        }
    };
    var dummy: u8 = 0;
    {
        const r = commitEdit(io, gpa, &fmtx, root, "mod.py", full, &.{.{ .kind = .replace, .anchor = "def a():", .text = "def a():  # edited" }}, base, "A", .{ .ctx = @ptrCast(&dummy), .check = &G.reject });
        switch (r) {
            .failed => |m| {
                try std.testing.expect(std.mem.startsWith(u8, m, "edit REJECTED"));
                gpa.free(m);
            },
            else => return error.ExpectedGateReject,
        }
        try std.testing.expect(G.saw_head); // the gate really saw (HEAD, candidate)
        const after = try std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20));
        defer gpa.free(after);
        try std.testing.expectEqualStrings(base, after); // untouched
    }
    {
        const r = commitEdit(io, gpa, &fmtx, root, "mod.py", full, &.{.{ .kind = .replace, .anchor = "def a():", .text = "def a():  # edited" }}, base, "A", .{ .ctx = @ptrCast(&dummy), .check = &G.accept });
        try std.testing.expect(r == .committed);
    }
}
