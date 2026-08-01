//! Thin client over the `neuron.exe` CLI — the app dogfoods neuron-db as its own datastore.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// COST PROBE — bumped only in test builds. Every neuron-db call in the app funnels through `exec`,
/// so this counts PROCESS SPAWNS, which is what this file's startup-cost claims are actually about.
///
/// COUNTED, NOT TIMED, deliberately. A wall-clock budget on a dev box measures Defender, OneDrive
/// and whatever else is running; it flakes, and a gate that cries wolf gets muted — worse than no
/// gate, because now the muting is a habit. A spawn count is deterministic and identical on every
/// machine, so it can be asserted EXACTLY. See harness/TESTING.md.
pub var spawn_probe: u64 = 0;

pub const Neuron = struct {
    gpa: std.mem.Allocator,
    io: Io,
    bin: []const u8,
    db: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: Io, bin: []const u8, db: []const u8) Neuron {
        return .{ .gpa = gpa, .io = io, .bin = bin, .db = db };
    }

    fn exec(self: Neuron, argv: []const []const u8) ![]u8 {
        if (builtin.is_test) spawn_probe += 1;
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

    /// Scope names under `prefix`, EXCLUDING neuron-db's per-scope satellites (`<scope>::var`,
    /// `::instr`, `::stance`, `::affect`, `::persona`).
    ///
    /// Those satellites are created by `forget` — and since `put` is forget-then-observe, EVERY
    /// key-value record here has five of them. They are not records: `export` on one returns
    /// nothing. Every caller of this function (api_keys.warm, auth_core's user + session warms,
    /// key_vault.list) then spent one `neuron export` SUBPROCESS on each, so a store holding N
    /// records was paying 6N spawns to read N values — at every startup, growing with every key
    /// ever created, revoked ones included. Filtering here rather than at the four call sites
    /// because this client is the only thing that reads scope listings; the hive's own memory
    /// surface goes through Mem/oscillation and never touches it.
    pub fn scopes(self: Neuron, prefix: []const u8) ![][]u8 {
        const argv = [_][]const u8{ self.bin, "--db", self.db, "list" };
        const out = try self.exec(&argv);
        defer self.gpa.free(out);
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| self.gpa.free(s);
            list.deinit(self.gpa);
        }
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \r\t");
            if (t.len == 0 or t[0] == '#') continue;
            if (std.mem.indexOf(u8, t, "::") != null) continue; // a satellite, not a record
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

/// The real environment, so a spawned child comes up with TEMP/SystemRoot (harness/TESTING.md).
fn testEnviron() std.process.Environ {
    return if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

const NEURON_BIN = if (builtin.os.tag == .windows) "bin/neuron.exe" else "bin/neuron";

/// Test values here are long, mixed-alphanumeric base64 — NOT short tokens like "v" or "first" —
/// and that is load-bearing, not decoration.
///
/// neuron-db ATOMISES what it is given into facts, and stores NOTHING for input it cannot atomise:
/// `observe s "hello world"` prints `stored 0 fact(s)` and exits 0. So `put` reports success, the
/// scope still appears in `list` (the `forget` inside put registers it), and a later `get` reads
/// null. Silent data loss behind a success return. Every real caller stores base64 of a JSON record,
/// which always atomises — so tests must use that same shape or they are asserting against a store
/// that quietly kept nothing.
///
/// The old 7-char probe `cHJvYmU` was one of the dropped shapes, so the live test below returned
/// SkipZigTest on EVERY machine — reported as "no binary on this box", which was false and is why it
/// went unnoticed for so long. Its assertions had never run, including the satellite spawn guard.
/// One shared probe now, so a value can never again be wrong in only one test.
const PROBE_V = "bmxfdmVpbF9jbGllbnRfcHJvYmVfdmFsdWU=";
const VAL_ONE = "eyJ2IjoxLCJ3aG8iOiJmaXJzdCB3cml0ZSJ9";
const VAL_TWO = "eyJ2IjoyLCJ3aG8iOiJzZWNvbmQgd3JpdGUifQ==";

/// A real WRITE→READ round trip, so "the store is dead" and "the binary is absent" are told apart:
/// both skip, but only after proving the store cannot actually hold a value.
fn probeStore(nb: Neuron, gpa: std.mem.Allocator) !void {
    nb.put("nlprobe", PROBE_V) catch return error.SkipZigTest;
    const got = (nb.get("nlprobe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, PROBE_V)) return error.SkipZigTest;
}

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

    try probeStore(nb, gpa); // no binary, or a store that cannot persist ⇒ skip, not fail

    // The property the header explains: `observe` APPENDS and `get` reads the FIRST line, so
    // without the forget inside put(), an update would never take — the stored value would stay the
    // ORIGINAL one forever, silently, for sessions, API keys, vault entries and the ledger alike.
    try nb.put("kv_test", VAL_ONE);
    try nb.put("kv_test", VAL_TWO);
    const now = (try nb.get("kv_test")) orelse return error.TestUnexpectedResult;
    defer gpa.free(now);
    try std.testing.expectEqualStrings(VAL_TWO, now);

    // A scope nobody wrote reads as null rather than as an error or an empty string.
    try std.testing.expect((try nb.get("kv_never_written")) == null);

    // del removes it, and a second del on the now-absent scope is still silent.
    nb.del("kv_test");
    try std.testing.expect((try nb.get("kv_test")) == null);
    nb.del("kv_test");

    // scopes() filters by prefix; unrelated scopes must not leak into a caller's listing (this is
    // how the vault and the key store enumerate per-user records without seeing each other's).
    try nb.put("pfx_a_one", VAL_ONE);
    try nb.put("pfx_a_two", VAL_ONE);
    try nb.put("pfx_b_one", VAL_ONE);
    const found = try nb.scopes("pfx_a_");
    defer {
        for (found) |s| gpa.free(s);
        gpa.free(found);
    }
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |s| try std.testing.expect(std.mem.startsWith(u8, s, "pfx_a_"));

    // …and EXACTLY two: neuron-db materialises five satellites per scope (::var, ::instr, ::stance,
    // ::affect, ::persona) the moment `forget` runs, which `put` does on every write. They are not
    // records — `export` on one returns nothing — but every caller here would spend a subprocess
    // discovering that, turning N records into 6N spawns at startup. The listing must stay clean.
    for (found) |s| try std.testing.expect(std.mem.indexOf(u8, s, "::") == null);
    const raw_list = try nb.exec(&[_][]const u8{ nb.bin, "--db", nb.db, "list" });
    defer gpa.free(raw_list);
    try std.testing.expect(std.mem.indexOf(u8, raw_list, "::") != null); // the satellites DO exist…
    // …so the filter above is doing real work, not asserting a store that never had any.
}

test "live: reading N records costs exactly N+1 spawns — the startup cost cannot silently regress" {
    // Startup was cut from 6N process spawns to N+1, and for a while the win rested on a filter no
    // test priced. A new satellite kind, or the filter being "simplified" away, would restore the old
    // cost with the oracle still green. This prices it.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-neuron-cost-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    const db = root ++ "/n.db";
    const nb = Neuron.init(gpa, io, NEURON_BIN, db);

    try probeStore(nb, gpa);

    const N = 3;
    for (0..N) |i| {
        var buf: [32]u8 = undefined;
        try nb.put(try std.fmt.bufPrint(&buf, "warm_{d}", .{i}), VAL_ONE);
    }

    // The shape every startup warm runs (api_keys.warm, auth_core's user + session warms,
    // key_vault.list): enumerate the records, then read each one.
    spawn_probe = 0;
    const found = try nb.scopes("warm_");
    defer {
        for (found) |s| gpa.free(s);
        gpa.free(found);
    }
    for (found) |s| if (try nb.get(s)) |v| gpa.free(v);
    const spent = spawn_probe;

    try std.testing.expectEqual(@as(usize, N), found.len);
    try std.testing.expectEqual(@as(u64, N + 1), spent); // one `list`, then one `export` per record

    // The number is only meaningful if the store actually holds the satellites the filter removes —
    // otherwise this passes on a store that never had any (the vacuity trap from 0037). Count what
    // the RAW listing carries under the same prefix: every one of those is a spawn the old code
    // spent, so the unfiltered cost here would be 1 + raw_total, not 1 + N.
    const raw = try nb.exec(&[_][]const u8{ nb.bin, "--db", nb.db, "list" });
    defer gpa.free(raw);
    var raw_total: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "warm_")) raw_total += 1;
    }
    // Deliberately NOT asserting the exact satellite count: how many neuron-db materialises is that
    // tool's business and may change, whereas "the filter drops real entries" is our claim to keep.
    try std.testing.expect(raw_total > found.len);
}

test "live: a value neuron-db cannot atomise is dropped SILENTLY — put still reports success" {
    // The assumption the whole KV layer rests on, written down and priced. Sessions, API keys, vault
    // entries, user records and the billing ledger are all stored as base64 of a JSON record, and
    // that shape survives; a short opaque token does not, and NOTHING reports the loss — `observe`
    // exits 0, put() returns void, and the scope even shows up in `list`. This is what made the
    // upsert test above skip on every machine while looking like a missing binary (ledger 0053).
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-neuron-drop-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    const nb = Neuron.init(gpa, io, NEURON_BIN, root ++ "/n.db");

    try probeStore(nb, gpa);

    // What every real caller stores: round-trips byte for byte. If THIS ever fails, every stateful
    // write the server makes is being silently discarded — the loudest thing in this file.
    try nb.put("kv_real", VAL_ONE);
    const real = (try nb.get("kv_real")) orelse return error.TestUnexpectedResult;
    defer gpa.free(real);
    try std.testing.expectEqualStrings(VAL_ONE, real);

    // CANARY, not a requirement: we do not WANT short values dropped, we depend on knowing that they
    // are. put() succeeds, and the read comes back null. If a neuron-db upgrade starts storing these,
    // this line goes red — that is good news arriving deliberately instead of as a mystery, and the
    // fix is to re-read this contract, not to delete the assertion.
    try nb.put("kv_tiny", "hello world");
    try std.testing.expect((try nb.get("kv_tiny")) == null);
}
