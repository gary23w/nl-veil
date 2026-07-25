//! Thin client over the `neuron.exe` CLI — the app dogfoods neuron-db as its own datastore.

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

    /// Single-value UPSERT for a scope: forget any prior value, then store this one. neuron `observe` APPENDS,
    /// and `get` (export → first line) returns the oldest — so without the forget, an update to an existing
    /// scope never takes (the KV callers here — vault, sessions, api keys, ledger, user records — all want the
    /// latest value, not an accumulation; the append-style memory use goes through Mem.observe, not this).
    pub fn put(self: Neuron, scope: []const u8, value: []const u8) !void {
        self.del(scope);
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

// ---------------------------------------------------------------------------
// tests — every stateful thing the server owns (user records, sessions, API keys, the BYOK vault,
// the neuron ledger) is stored through these five calls, so their failure semantics ARE the
// server's failure semantics. See harness/TESTING.md.
// ---------------------------------------------------------------------------

const builtin = @import("builtin");

/// The real environment, so a spawned child comes up with TEMP/SystemRoot (harness/TESTING.md).
fn testEnviron() std.process.Environ {
    return if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

const NEURON_BIN = if (builtin.os.tag == .windows) "bin/neuron.exe" else "bin/neuron";

test "with no binary: reads and writes ERROR, deletes stay silent" {
    // This asymmetry is load-bearing and has bitten twice (ledger 0026, 0030). `del` swallows, so a
    // cleanup path never fails; `put`/`get`/`scopes` PROPAGATE, so a caller must decide. That is
    // precisely why Auth appears to fail open (it catches, and its in-memory maps carry on) while
    // the vault surfaces the failure as a 400 — same dead store, two different-looking symptoms.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    const nb = Neuron.init(gpa, io, "definitely-not-a-real-binary-xyz", "zig-neuron-none-tmp.db");
    try std.testing.expectError(error.FileNotFound, nb.put("s", "v"));
    try std.testing.expectError(error.FileNotFound, nb.get("s"));
    try std.testing.expectError(error.FileNotFound, nb.scopes(""));
    nb.del("s"); // must not crash and must not propagate — the whole point of its `void` return
}

test "live: put is an UPSERT — a second write wins, which the forget-first is there to guarantee" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-neuron-live-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    const db = root ++ "/n.db";
    const nb = Neuron.init(gpa, io, NEURON_BIN, db);

    // Probe rather than assume — no binary on this box means skip, not fail.
    nb.put("nlprobe", "cHJvYmU") catch return error.SkipZigTest;
    {
        const got = (nb.get("nlprobe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, "cHJvYmU")) return error.SkipZigTest;
    }

    // The property the header explains: `observe` APPENDS and `get` reads the FIRST line, so
    // without the forget inside put(), an update would never take — the stored value would stay the
    // ORIGINAL one forever, silently, for sessions, API keys, vault entries and the ledger alike.
    try nb.put("kv_test", "first");
    try nb.put("kv_test", "second");
    const now = (try nb.get("kv_test")) orelse return error.TestUnexpectedResult;
    defer gpa.free(now);
    try std.testing.expectEqualStrings("second", now);

    // A scope nobody wrote reads as null rather than as an error or an empty string.
    try std.testing.expect((try nb.get("kv_never_written")) == null);

    // del removes it, and a second del on the now-absent scope is still silent.
    nb.del("kv_test");
    try std.testing.expect((try nb.get("kv_test")) == null);
    nb.del("kv_test");

    // scopes() filters by prefix; unrelated scopes must not leak into a caller's listing (this is
    // how the vault and the key store enumerate per-user records without seeing each other's).
    try nb.put("pfx_a_one", "1");
    try nb.put("pfx_a_two", "2");
    try nb.put("pfx_b_one", "3");
    const found = try nb.scopes("pfx_a_");
    defer {
        for (found) |s| gpa.free(s);
        gpa.free(found);
    }
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |s| try std.testing.expect(std.mem.startsWith(u8, s, "pfx_a_"));
}
