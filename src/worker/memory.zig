//! The worker's neuron-db memory — shells out to the neuron CLI (the Rust core), the same ops the Python

const std = @import("std");

pub const Mem = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    db: []const u8,
    wmtx: ?*std.Io.Mutex = null,
    environ: ?*const std.process.Environ.Map = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, db: []const u8) Mem {
        return .{ .gpa = gpa, .io = io, .bin = bin, .db = db };
    }

    fn lockW(self: Mem) void {
        if (self.wmtx) |m| m.lockUncancelable(self.io);
    }
    fn unlockW(self: Mem) void {
        if (self.wmtx) |m| m.unlock(self.io);
    }

    fn run(self: Mem, args: []const []const u8) ?[]u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        argv.appendSlice(self.gpa, &.{ self.bin, "--db", self.db }) catch return null;
        argv.appendSlice(self.gpa, args) catch return null;
        const r = std.process.run(self.gpa, self.io, .{ .argv = argv.items, .stdout_limit = .limited(1 << 20) }) catch return null;
        self.gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) {
            self.gpa.free(r.stdout);
            return null;
        }
        return r.stdout;
    }

    pub fn observe(self: Mem, scope: []const u8, fact: []const u8) u32 {
        self.lockW();
        defer self.unlockW();
        const out = self.run(&.{ "observe", scope, fact }) orelse return 0;
        defer self.gpa.free(out);
        return std.fmt.parseInt(u32, std.mem.trim(u8, out, " \r\n\t"), 10) catch 0;
    }

    pub fn recall(self: Mem, scope: []const u8, query: []const u8) []u8 {
        const out = self.run(&.{ "recall", scope, query }) orelse return self.gpa.dupe(u8, "") catch @constCast("");
        return out;
    }

    pub fn import(self: Mem, pack_path: []const u8, scope: []const u8, cap: u32) u32 {
        self.lockW();
        defer self.unlockW();
        var capbuf: [16]u8 = undefined;
        const caps = std.fmt.bufPrint(&capbuf, "{d}", .{cap}) catch "400";
        const out = self.run(&.{ "--json", "import", pack_path, "--scope", scope, "--dedup", "--flush", caps }) orelse return 0;
        defer self.gpa.free(out);
        const key = "\"stored\":";
        const i = std.mem.indexOf(u8, out, key) orelse return 0;
        const rest = out[i + key.len ..];
        var j: usize = 0;
        while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') j += 1;
        return std.fmt.parseInt(u32, rest[0..j], 10) catch 0;
    }

    pub fn coverage(self: Mem, scope: []const u8, query: []const u8) f32 {
        const out = self.run(&.{ "--json", "recall", scope, query }) orelse return 0.0;
        defer self.gpa.free(out);
        const key = "\"coverage\":";
        const i = std.mem.indexOf(u8, out, key) orelse return 0.0;
        const rest = out[i + key.len ..];
        var j: usize = 0;
        while (j < rest.len and (rest[j] == '.' or (rest[j] >= '0' and rest[j] <= '9'))) j += 1;
        return std.fmt.parseFloat(f32, rest[0..j]) catch 0.0;
    }

    pub fn assoc(self: Mem, scope: []const u8, query: []const u8, hops: u32, k: u32) []u8 {
        const out = self.runEnv(&.{ "assoc", scope, query }, hops, k) orelse return self.gpa.dupe(u8, "") catch @constCast("");
        return out;
    }

    fn runEnv(self: Mem, args: []const []const u8, hops: u32, k: u32) ?[]u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        argv.appendSlice(self.gpa, &.{ self.bin, "--db", self.db }) catch return null;
        argv.appendSlice(self.gpa, args) catch return null;
        var hbuf: [16]u8 = undefined;
        var kbuf: [16]u8 = undefined;
        const hs = std.fmt.bufPrint(&hbuf, "{d}", .{hops}) catch "3";
        const ks = std.fmt.bufPrint(&kbuf, "{d}", .{k}) catch "10";
        var opts: std.process.RunOptions = .{ .argv = argv.items, .stdout_limit = .limited(1 << 20) };
        var env: ?std.process.Environ.Map = if (self.environ) |pe| (pe.clone(self.gpa) catch null) else null;
        defer if (env) |*m| m.deinit();
        if (env) |*m| {
            m.put("NEURON_HOPS", hs) catch {};
            m.put("NEURON_K", ks) catch {};
            opts.environ_map = m;
        }
        const r = std.process.run(self.gpa, self.io, opts) catch return null;
        self.gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) {
            self.gpa.free(r.stdout);
            return null;
        }
        return r.stdout;
    }

    pub fn stance(self: Mem, scope: []const u8, topic: []const u8, feeling: []const u8) void {
        self.lockW();
        defer self.unlockW();
        if (self.run(&.{ "stance", scope, topic, feeling })) |o| self.gpa.free(o);
    }

    pub fn mood(self: Mem, scope: []const u8, m: []const u8) void {
        self.lockW();
        defer self.unlockW();
        if (self.run(&.{ "mood", scope, m })) |o| self.gpa.free(o);
    }

    pub fn affect(self: Mem, scope: []const u8) []u8 {
        return self.run(&.{ "affect", scope }) orelse (self.gpa.dupe(u8, "") catch @constCast(""));
    }

    pub fn list(self: Mem, scope: []const u8) []u8 {
        const out = self.run(&.{ "export", scope }) orelse return self.gpa.dupe(u8, "") catch @constCast("");
        if (std.mem.indexOfScalar(u8, out, '\n')) |nl| {
            if (out.len > 0 and out[0] == '#') {
                const body = self.gpa.dupe(u8, std.mem.trim(u8, out[nl + 1 ..], " \r\n\t")) catch out;
                if (body.ptr != out.ptr) self.gpa.free(out);
                return body;
            }
        }
        return out;
    }

    pub fn persona(self: Mem, scope: []const u8, vals: [6]f32) void {
        var bufs: [6][16]u8 = undefined;
        var args: [8][]const u8 = undefined;
        args[0] = "persona";
        args[1] = scope;
        for (vals, 0..) |v, i| args[2 + i] = std.fmt.bufPrint(&bufs[i], "{d:.2}", .{v}) catch "0.5";
        self.lockW();
        defer self.unlockW();
        if (self.run(args[0..])) |o| self.gpa.free(o);
    }

    pub fn factCount(self: Mem, scope: []const u8) u32 {
        const out = self.run(&.{ "--json", "stats", scope }) orelse return 0;
        defer self.gpa.free(out);
        const key = "\"facts\":";
        const i = std.mem.indexOf(u8, out, key) orelse return 0;
        const rest = out[i + key.len ..];
        var j: usize = 0;
        while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') j += 1;
        return std.fmt.parseInt(u32, rest[0..j], 10) catch 0;
    }
};
