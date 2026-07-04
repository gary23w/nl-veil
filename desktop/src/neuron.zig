//! neurondb.zig — a minimal client for the chat's HIPPOCAMPUS. Spawns the `neuron` CLI (the same binary the
//! swarm minds use) against a chat-local sqlite db to OBSERVE conversation turns + cast findings as neurons and
//! ASSOC-recall the relevant ones into the next prompt. Everything degrades to a silent no-op if the binary or
//! db path is unavailable, so the chat behaves EXACTLY as before whenever neuron-db isn't present or errors.

const std = @import("std");
const Io = std.Io;

pub const Db = struct {
    gpa: std.mem.Allocator,
    io: Io,
    bin: []const u8 = "", // path to the neuron binary ("" = disabled → all ops no-op)
    db: []const u8 = "", //  path to the chat sqlite ("" = disabled)

    fn run(self: Db, args: []const []const u8) ?[]u8 {
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
        const t = std.mem.trim(u8, text, " \r\n\t");
        if (t.len < 3) return;
        if (self.run(&.{ "observe", scope, t[0..@min(t.len, 1400)] })) |o| self.gpa.free(o);
    }

    /// Spreading-activation recall of the facts relevant to `query`, copied into `out`. Empty slice on miss.
    pub fn recall(self: Db, scope: []const u8, query: []const u8, out: []u8) []const u8 {
        const q = std.mem.trim(u8, query, " \r\n\t");
        if (q.len < 3) return out[0..0];
        const o = self.run(&.{ "assoc", scope, q[0..@min(q.len, 400)] }) orelse return out[0..0];
        defer self.gpa.free(o);
        const trimmed = std.mem.trim(u8, o, " \r\n\t");
        // neuron prints "(the hive knows nothing…)" style lines on a miss — treat a short/parenthetical reply
        // as empty so we never inject noise.
        if (trimmed.len < 24 or trimmed[0] == '(') return out[0..0];
        const n = @min(trimmed.len, out.len);
        @memcpy(out[0..n], trimmed[0..n]);
        return out[0..n];
    }
};

/// Locate the neuron binary near the app (cwd is the nl-veil home when launched normally). "" if not found;
/// caller owns the returned slice.
pub fn findBin(gpa: std.mem.Allocator, io: Io) []const u8 {
    const cands = [_][]const u8{ "bin/neuron.exe", "bin/neuron", "neuron.exe", "./neuron.exe", "../bin/neuron.exe", "../bin/neuron" };
    for (cands) |c| {
        if (Io.Dir.cwd().statFile(io, c, .{})) |_| {
            return gpa.dupe(u8, c) catch "";
        } else |_| {}
    }
    return "";
}
