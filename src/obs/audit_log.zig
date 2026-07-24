//! Append-only, hash-chained audit log for privileged actions (plan changes, bans/deletes, force-kills)

const std = @import("std");

const GENESIS: [64]u8 = [_]u8{'0'} ** 64;

pub const AuditLog = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    mu: std.Io.Mutex = .init,
    seq: u64 = 0,
    last_hash: [64]u8 = GENESIS,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) AuditLog {
        const path = std.fmt.allocPrint(gpa, "{s}/audit.log", .{data_dir}) catch data_dir;
        var self = AuditLog{ .gpa = gpa, .io = io, .path = path };
        self.recover();
        return self;
    }

    fn recover(self: *AuditLog) void {
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, .limited(64 << 20)) catch return;
        defer self.gpa.free(data);
        var last: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, data, "\r\n"), '\n');
        while (it.next()) |ln| if (ln.len > 0) {
            last = ln;
        };
        const ll = last orelse return;
        const parsed = std.json.parseFromSlice(struct { seq: u64 = 0, hash: []const u8 = "" }, self.gpa, ll, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        self.seq = parsed.value.seq;
        if (parsed.value.hash.len == 64) @memcpy(self.last_hash[0..], parsed.value.hash[0..64]);
    }

    fn chain(prev: *const [64]u8, seq: u64, ts: i64, actor: []const u8, action: []const u8, target: []const u8) [64]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(prev);
        var nb: [320]u8 = undefined;
        const pre = std.fmt.bufPrint(&nb, "|{d}|{d}|{s}|{s}|{s}", .{ seq, ts, actor, action, target }) catch "";
        h.update(pre);
        var dig: [32]u8 = undefined;
        h.final(&dig);
        return std.fmt.bytesToHex(dig, .lower);
    }

    // The JSON layer escapes; the hash preimage stays the RAW field bytes (chain() below), and
    // verify() recomputes from the PARSED (unescaped) fields — so escaping here changes nothing
    // about existing chains, it only makes a quoted/newlined field parseable instead of corrupting
    // the whole log's readability.
    fn jesc(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) !void {
        for (s) |c| switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => if (c < 0x20) {
                // \u-escape, never drop: the hash preimage is the RAW bytes, so verify() must be
                // able to recover them exactly from the JSON.
                var ub: [8]u8 = undefined;
                try out.appendSlice(gpa, std.fmt.bufPrint(&ub, "\\u{x:0>4}", .{c}) catch return);
            } else try out.append(gpa, c),
        };
    }

    pub fn record(self: *AuditLog, actor: []const u8, action: []const u8, target: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.seq += 1;
        const ts = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const hex = chain(&self.last_hash, self.seq, ts, actor, action, target);
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(self.gpa);
        var nb: [96]u8 = undefined;
        line.appendSlice(self.gpa, std.fmt.bufPrint(&nb, "{{\"seq\":{d},\"ts\":{d},\"actor\":\"", .{ self.seq, ts }) catch return) catch return;
        jesc(&line, self.gpa, actor) catch return;
        line.appendSlice(self.gpa, "\",\"action\":\"") catch return;
        jesc(&line, self.gpa, action) catch return;
        line.appendSlice(self.gpa, "\",\"target\":\"") catch return;
        jesc(&line, self.gpa, target) catch return;
        line.appendSlice(self.gpa, "\",\"prev\":\"") catch return;
        line.appendSlice(self.gpa, self.last_hash[0..]) catch return;
        line.appendSlice(self.gpa, "\",\"hash\":\"") catch return;
        line.appendSlice(self.gpa, hex[0..]) catch return;
        line.appendSlice(self.gpa, "\"}\n") catch return;
        self.append(line.items);
        @memcpy(self.last_hash[0..], hex[0..]);
    }

    fn append(self: *AuditLog, line: []const u8) void {
        const dir = std.Io.Dir.cwd();
        const existing = dir.readFileAlloc(self.io, self.path, self.gpa, .limited(64 << 20)) catch &[_]u8{};
        defer if (existing.len > 0) self.gpa.free(existing);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);
        buf.appendSlice(self.gpa, existing) catch return;
        buf.appendSlice(self.gpa, line) catch return;
        dir.writeFile(self.io, .{ .sub_path = self.path, .data = buf.items }) catch {};
    }

    pub fn verify(self: *AuditLog) !u64 {
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, .limited(64 << 20)) catch return 0;
        defer self.gpa.free(data);
        var prev: [64]u8 = GENESIS;
        var n: u64 = 0;
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, data, "\r\n"), '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            const Rec = struct { seq: u64 = 0, ts: i64 = 0, actor: []const u8 = "", action: []const u8 = "", target: []const u8 = "", prev: []const u8 = "", hash: []const u8 = "" };
            const parsed = std.json.parseFromSlice(Rec, self.gpa, ln, .{ .ignore_unknown_fields = true }) catch return error.AuditCorrupt;
            defer parsed.deinit();
            const r = parsed.value;
            if (r.prev.len != 64 or !std.mem.eql(u8, r.prev, prev[0..])) return error.AuditChainBroken;
            const want = chain(&prev, r.seq, r.ts, r.actor, r.action, r.target);
            if (r.hash.len != 64 or !std.mem.eql(u8, r.hash, want[0..])) return error.AuditHashMismatch;
            @memcpy(prev[0..], want[0..]);
            n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// tests — the tamper-evidence contract, on a real file
// ---------------------------------------------------------------------------

test "audit chain: records verify, recovery resumes the chain across a restart" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-audit-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    var log = AuditLog.init(gpa, io, root);
    defer gpa.free(log.path);
    log.record("admin@x", "ban", "u7");
    log.record("admin@x", "kill_swarm", "sw-abc");
    log.record("root", "plan_change", "u7:pro");
    try std.testing.expectEqual(@as(u64, 3), try log.verify());

    // restart: a fresh instance recovers seq + last_hash from the tail and keeps chaining
    var log2 = AuditLog.init(gpa, io, root);
    defer gpa.free(log2.path);
    try std.testing.expectEqual(@as(u64, 3), log2.seq);
    log2.record("admin@x", "unban", "u7");
    try std.testing.expectEqual(@as(u64, 4), try log2.verify());
}

test "audit chain: quotes, backslashes, newlines and control bytes in fields survive the round trip" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-audit-esc-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    var log = AuditLog.init(gpa, io, root);
    defer gpa.free(log.path);
    log.record("a\"b\\c", "do\nthing", "t\x01\targ");
    try std.testing.expectEqual(@as(u64, 1), try log.verify());
}

test "audit chain: a flipped byte, a removed entry, and a garbage line are each detected" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-audit-tamper-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    var log = AuditLog.init(gpa, io, root);
    defer gpa.free(log.path);
    log.record("admin", "ban", "victim-one");
    log.record("admin", "delete", "victim-two");
    log.record("admin", "restore", "victim-two");
    const clean = std.Io.Dir.cwd().readFileAlloc(io, log.path, gpa, .limited(1 << 20)) catch unreachable;
    defer gpa.free(clean);

    // 1) flip a field byte: rewriting history breaks that entry's hash
    {
        const doctored = try std.mem.replaceOwned(u8, gpa, clean, "victim-one", "victim-0ne");
        defer gpa.free(doctored);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log.path, .data = doctored }) catch unreachable;
        try std.testing.expectError(error.AuditHashMismatch, log.verify());
    }
    // 2) delete the middle entry: the next entry's prev no longer matches
    {
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, clean, "\r\n"), '\n');
        var doctored: std.ArrayListUnmanaged(u8) = .empty;
        defer doctored.deinit(gpa);
        var i: usize = 0;
        while (lines.next()) |ln| : (i += 1) {
            if (i == 1) continue; // drop the second record
            try doctored.appendSlice(gpa, ln);
            try doctored.append(gpa, '\n');
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log.path, .data = doctored.items }) catch unreachable;
        try std.testing.expectError(error.AuditChainBroken, log.verify());
    }
    // 3) a non-JSON line is corruption, loudly
    {
        var doctored: std.ArrayListUnmanaged(u8) = .empty;
        defer doctored.deinit(gpa);
        try doctored.appendSlice(gpa, clean);
        try doctored.appendSlice(gpa, "not json at all\n");
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log.path, .data = doctored.items }) catch unreachable;
        try std.testing.expectError(error.AuditCorrupt, log.verify());
    }
}
