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

    pub fn record(self: *AuditLog, actor: []const u8, action: []const u8, target: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.seq += 1;
        const ts = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const hex = chain(&self.last_hash, self.seq, ts, actor, action, target);
        const line = std.fmt.allocPrint(self.gpa, "{{\"seq\":{d},\"ts\":{d},\"actor\":\"{s}\",\"action\":\"{s}\",\"target\":\"{s}\",\"prev\":\"{s}\",\"hash\":\"{s}\"}}\n", .{ self.seq, ts, actor, action, target, self.last_hash[0..], hex[0..] }) catch return;
        defer self.gpa.free(line);
        self.append(line);
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
