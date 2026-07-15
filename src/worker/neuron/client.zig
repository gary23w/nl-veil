//! Thin client over the `neuron.exe` CLI — Neuron-loops dogfoods neuron-db as its own datastore

const std = @import("std");
const Io = std.Io;

pub const Neuron = struct {
    gpa: std.mem.Allocator,
    io: Io,
    bin: []const u8,
    db: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: Io, bin: []const u8, db: []const u8) Neuron {
        return .{ .gpa = gpa, .io = io, .bin = bin, .db = db };
    }

    fn exec(self: Neuron, argv: []const []const u8) ![]u8 {
        const res = try std.process.run(self.gpa, self.io, .{ .argv = argv });
        self.gpa.free(res.stderr);
        return res.stdout;
    }

    pub fn put(self: Neuron, scope: []const u8, value: []const u8) !void {
        const argv = [_][]const u8{ self.bin, "--db", self.db, "observe", scope, value };
        const out = try self.exec(&argv);
        self.gpa.free(out);
    }

    pub fn get(self: Neuron, scope: []const u8) !?[]u8 {
        const argv = [_][]const u8{ self.bin, "--db", self.db, "export", scope };
        const out = try self.exec(&argv);
        defer self.gpa.free(out);
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \r\t");
            if (t.len == 0 or t[0] == '#') continue;
            return try self.gpa.dupe(u8, t);
        }
        return null;
    }

    pub fn del(self: Neuron, scope: []const u8) void {
        const argv = [_][]const u8{ self.bin, "--db", self.db, "forget", scope };
        const out = self.exec(&argv) catch return;
        self.gpa.free(out);
    }

    pub fn scopes(self: Neuron, prefix: []const u8) ![][]u8 {
        const argv = [_][]const u8{ self.bin, "--db", self.db, "list" };
        const out = try self.exec(&argv);
        defer self.gpa.free(out);
        var list: std.ArrayList([]u8) = .empty;
        errdefer list.deinit(self.gpa);
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \r\t");
            if (t.len == 0 or t[0] == '#') continue;
            if (prefix.len == 0 or std.mem.startsWith(u8, t, prefix)) {
                try list.append(self.gpa, try self.gpa.dupe(u8, t));
            }
        }
        return list.toOwnedSlice(self.gpa);
    }
};
