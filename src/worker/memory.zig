//! The worker's neuron-db memory — shells out to the neuron CLI (the Rust core), the same ops the Python
//! memory.py used: observe (store a fact), recall (top-k lexical), stance (a feeling toward a topic), mood.
//! One db per swarm, one scope per mind. Best-effort: a memory error never crashes a tick.
const std = @import("std");

/// True for a round stamp like `r12` / `r1622` — 'r' then ≥1 digits. Mirrors neuron-db trust::is_round_stamp.
fn isRoundStamp(s: []const u8) bool {
    if (s.len < 2 or s[0] != 'r') return false;
    for (s[1..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

pub const Mem = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    db: []const u8,
    wmtx: ?*std.Io.Mutex = null,
    environ: ?*const std.process.Environ.Map = null,
    trust: bool = false,

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

    /// Store one fact. Returns the running fact count (0 on failure).
    pub fn observe(self: Mem, scope: []const u8, fact: []const u8) u32 {
        self.lockW();
        defer self.unlockW();
        const out = self.run(&.{ "observe", scope, fact }) orelse return 0;
        defer self.gpa.free(out);
        return std.fmt.parseInt(u32, std.mem.trim(u8, out, " \r\n\t"), 10) catch 0;
    }

    pub fn replace(self: Mem, scope: []const u8, fact: []const u8) void {
        self.lockW();
        if (self.run(&.{ "forget", scope })) |o| self.gpa.free(o);
        self.unlockW();
        _ = self.observe(scope, fact);
    }

    /// Single best fact (RecallOne) as a text block. Caller frees. Empty when recall abstains (no match).
    pub fn recall(self: Mem, scope: []const u8, query: []const u8) []u8 {
        const out = self.run(&.{ "recall", scope, query }) orelse return self.gpa.dupe(u8, "") catch @constCast("");
        return out;
    }

    /// Bulk-load a fact pack (.facts/.jsonl) into `scope` via the neuron CLI `import`. Returns the stored count
    /// (0 on any failure — missing/garbage pack is a safe no-op). `--json` is mandatory (the count prints to
    /// stdout only under --json) and must come FIRST (the CLI strips a leading --json before dispatch). --dedup
    /// makes re-deploy idempotent; --flush caps the load.
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

    /// The native COVERAGE signal: `recall --json` returns {"fact":..,"coverage":0.NN} — the fraction of the
    /// query's cue-stems present in the single best-matching fact. It's a lexical PRESENCE probe (not corpus
    /// sufficiency), so use it only as a cheap gate. 0.0 on a miss (exit 3 => Mem.run null) = maximal gap. Read.
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

    /// Associative SPREADING-ACTIVATION recall: the CHAINED facts a multi-hop query needs — facts that may
    /// share no words with the query but are reached by following shared-entity links (e.g. EmberOak ->
    /// Portland -> roasting district). This is the closed-loop "self-RAG" the product promises; flat `recall`
    /// returns one fact, `assoc` returns the whole reachable neighborhood. Newline-joined facts; caller frees.
    pub fn assoc(self: Mem, scope: []const u8, query: []const u8, hops: u32, k: u32) []u8 {
        const out = if (self.trust)
            self.runEnv(&.{ "assoc", scope, query, "--trust" }, hops, k)
        else
            self.runEnv(&.{ "assoc", scope, query }, hops, k);
        return out orelse self.gpa.dupe(u8, "") catch @constCast("");
    }

    /// Reward the tag-classes recalled this round by the grounded fitness Δ (delta in [-1,1]). Writes the
    /// global trust ledger in this DB (lazily created on first reward). Write-locked; best-effort. ENGINE-
    /// DRIVEN ONLY — the minds never call this, so a mind cannot inflate its own class's trust.
    pub fn trustReward(self: Mem, delta: f32, classes: []const []const u8) void {
        if (classes.len == 0) return;
        self.lockW();
        defer self.unlockW();
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        var dbuf: [32]u8 = undefined;
        const ds = std.fmt.bufPrint(&dbuf, "{d:.4}", .{delta}) catch return;
        argv.appendSlice(self.gpa, &.{ "trust_reward", ds }) catch return;
        argv.appendSlice(self.gpa, classes) catch return;
        if (self.run(argv.items)) |out| self.gpa.free(out);
    }

    /// PLAIN (untrusted) wide recall on `scope` for `query`, returning the DISTINCT tag-classes of the
    /// surfaced facts — leading "[tok]" -> tok, else the scope; lowercased; caller owns each + the slice.
    /// The engine uses this to choose which classes to reward; forcing NO --trust keeps the sample honest
    /// (it sees every class present, not only the already-trusted ones), so new good classes can be found.
    pub fn sampleClassesAlloc(self: Mem, scope: []const u8, query: []const u8, hops: u32, k: u32) ?[][]u8 {
        const out = self.runEnv(&.{ "assoc", scope, query }, hops, k) orelse return null;
        defer self.gpa.free(out);
        var acc: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (acc.items) |c| self.gpa.free(c);
            acc.deinit(self.gpa);
        }
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line0| {
            const line = std.mem.trim(u8, line0, " \r\t");
            if (line.len == 0) continue;
            var cls: []const u8 = scope;
            if (line[0] == '[') {
                if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                    const inside = line[1..end];
                    var tk = std.mem.tokenizeAny(u8, inside, " \t");
                    var first: ?[]const u8 = null;
                    var last: []const u8 = "";
                    while (tk.next()) |t| {
                        if (first == null) first = t;
                        last = t;
                    }
                    if (first) |f| {
                        cls = if (isRoundStamp(last)) "self" else f;
                    }
                }
            }
            const low = std.ascii.allocLowerString(self.gpa, cls) catch continue;
            var dup = false;
            for (acc.items) |c| {
                if (std.mem.eql(u8, c, low)) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                self.gpa.free(low);
                continue;
            }
            acc.append(self.gpa, low) catch {
                self.gpa.free(low);
                break;
            };
            if (acc.items.len >= 16) break;
        }
        if (acc.items.len == 0) {
            acc.deinit(self.gpa);
            return null;
        }
        return acc.toOwnedSlice(self.gpa) catch null;
    }

    /// Like `run`, but injects NEURON_HOPS/NEURON_K into a CLONE of the worker env (the CLI reads them only
    /// from the environment). Falls back to inherited env (CLI defaults) when no environ is wired.
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

    /// The dynamic persona directive: a vivid "you are not a neutral assistant — here's how you feel and how
    /// it shows in your voice" line that fuses the mind's Big-Five persona with its ACCUMULATED stances + mood.
    /// This is what makes a mind's personality actually emerge over a run. Caller frees; empty on failure.
    pub fn affect(self: Mem, scope: []const u8) []u8 {
        return self.run(&.{ "affect", scope }) orelse (self.gpa.dupe(u8, "") catch @constCast(""));
    }

    /// Export ALL facts in a (small) scope as a newline block, header stripped — for the playbook, where every
    /// directive must be injected regardless of query relevance (a query-based recall would miss them). Caller
    /// frees. Empty when the scope is empty.
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

    /// Set the mind's innate Big-Five persona: `persona <scope> O C E A N reactivity` (no-op if the cortex
    /// lacks the `personality` feature). vals = [openness, conscientiousness, extraversion, agreeableness,
    /// neuroticism, reactivity].
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

    /// Real total facts under a scope, from `stats --json` ({"facts":N,...}). The old impl shelled a
    /// nonexistent `count` subcommand and always returned 0, so the worker fell back to the round number —
    /// i.e. the UI "facts" metric was fake. This reports the true stored count. 0 on failure.
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
