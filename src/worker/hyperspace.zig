//! hyperspace.zig — the in-process working-memory OSCILLATOR (Lever 2).

const std = @import("std");
const oscillation = @import("oscillation.zig");
const Mem = oscillation.Mem;

// Per-mind field capacity — bounds BOTH RAM (~250B/fact typical) AND the O(N^2) settle. Tunable via
// NL_HYPERSPACE_CAP; clamped to [MIN_FACTS, MAX_FACTS_CAP].
pub const DEFAULT_MAX_FACTS: usize = 160;
pub const MIN_FACTS: usize = 16;
pub const MAX_FACTS_CAP: usize = 4096;
const MAX_FACT_LEN: usize = 400; // hard byte cap per stored fact so a pathological long fact can't bloat the bound
const MAX_STEMS: usize = 24; // significant stems kept per fact
const SETTLE_ITERS: u32 = 4; // spreading-activation passes (converges fast on a bounded field)

fn dupEmpty(gpa: std.mem.Allocator) []u8 {
    return gpa.dupe(u8, "") catch @constCast("");
}

fn fnv(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

/// The stems whose overlap dominates memory routing: very common words carry no signal and would fuse every fact
/// into one blob, collapsing the hierarchy. A short stop-set keeps the graph meaningful.
fn isStop(w: []const u8) bool {
    const stops = [_][]const u8{
        "the",   "and",  "that", "this",  "with",  "from",  "have",  "will",   "your",  "what", "when", "which",
        "they",  "them", "then", "there", "their", "would", "could", "should", "about", "into", "over", "some",
        "than",  "very", "just", "also",  "been",  "were",  "each",  "more",   "most",  "such", "only", "these",
        "those", "here", "does", "done",  "using", "used",  "make",  "made",   "like",  "want", "need",
    };
    for (stops) |s| if (std.mem.eql(u8, w, s)) return true;
    return false;
}

/// Extract the sorted, unique stem-hashes of a fact (lowercased alnum tokens, length 4..40, stop-words dropped,
/// capped). Sorted so overlap is a linear merge. Caller owns the returned slice.
fn stemHashes(gpa: std.mem.Allocator, text: []const u8) []u64 {
    var set: std.ArrayListUnmanaged(u64) = .empty;
    defer set.deinit(gpa);
    var lb: [40]u8 = undefined;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?()[]{}\"'/\\<>=+*#`~|&%$@-_0123456789");
    while (it.next()) |tok| {
        if (tok.len < 4 or tok.len > 40) continue;
        for (tok, 0..) |c, i| lb[i] = std.ascii.toLower(c);
        const low = lb[0..tok.len];
        if (isStop(low)) continue;
        const h = fnv(low);
        var dup = false;
        for (set.items) |x| if (x == h) {
            dup = true;
            break;
        };
        if (!dup) set.append(gpa, h) catch {};
        if (set.items.len >= MAX_STEMS) break;
    }
    const owned = set.toOwnedSlice(gpa) catch return gpa.alloc(u64, 0) catch @as([]u64, &.{});
    std.mem.sort(u64, owned, {}, std.sort.asc(u64));
    return owned;
}

/// Intersection size of two SORTED stem-hash arrays — the cheap similarity kernel of the field.
fn interCount(a: []const u64, b: []const u64) u32 {
    var i: usize = 0;
    var j: usize = 0;
    var c: u32 = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) {
            c += 1;
            i += 1;
            j += 1;
        } else if (a[i] < b[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return c;
}

const Fact = struct {
    text: []u8, // owned
    stems: []u64, // owned, sorted unique
    r: f32 = 1.0, // radial: 0 = central hub (general), 1 = boundary leaf (specific)
    act: f32 = 0.0, // settled activation this pack
    deg: f32 = 0.0, // link-degree (Σ overlap with the rest of the field)
};

fn packLess(f: []const Fact, a: usize, b: usize) bool {
    // rank by settled activation, with a small skeleton boost so a few central hubs always make the cut
    return (f[a].act + 0.15 * (1.0 - f[a].r)) > (f[b].act + 0.15 * (1.0 - f[b].r));
}

pub const Field = struct {
    gpa: std.mem.Allocator, // MUST be a whole-run allocator (w.gpa), never the per-round arena
    facts: std.ArrayListUnmanaged(Fact) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    cap: usize = DEFAULT_MAX_FACTS, // per-hardware field size (NL_HYPERSPACE_CAP); bounds RAM + settle cost
    warm: bool = false, // has been seeded from the store at least once
    deg_dirty: bool = true, // facts changed since the last hierarchy compute -> recompute degree/radial
    settled: bool = false, // a settle() has run -> deg/r are meaningful for focus-independent eviction

    pub fn init(gpa: std.mem.Allocator) Field {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Field) void {
        for (self.facts.items) |f| {
            self.gpa.free(f.text);
            self.gpa.free(f.stems);
        }
        self.facts.deinit(self.gpa);
        self.seen.deinit(self.gpa);
    }

    /// Free fact at index k and drop its dedupe key (both, or the field leaks / mis-dedupes after eviction).
    fn evictAt(self: *Field, k: usize) void {
        const f = self.facts.items[k];
        _ = self.seen.remove(fnv(f.text));
        self.gpa.free(f.text);
        self.gpa.free(f.stems);
        _ = self.facts.swapRemove(k); // order is irrelevant — pack() re-sorts
        self.deg_dirty = true;
    }

    /// Absorb ONE fact into the field the instant the swarm creates it in-process (zero subprocess). Deduped by
    /// content hash. At capacity it evicts a FOCUS-INDEPENDENT victim — the least-connected (most peripheral)
    /// fact, so the general skeleton hubs survive — never a victim chosen by a stale previous focus's activation.
    pub fn observeLine(self: *Field, raw: []const u8) void {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len < 12) return; // skip fragments / headers
        const line = if (trimmed.len > MAX_FACT_LEN) trimmed[0..MAX_FACT_LEN] else trimmed; // hard per-fact byte cap
        const key = fnv(line);
        if (self.seen.contains(key)) return;
        if (self.facts.items.len >= self.cap) {
            var victim: usize = 0;
            if (self.settled) {
                var lo: f32 = std.math.floatMax(f32);
                for (self.facts.items, 0..) |fa, i| if (fa.deg < lo) {
                    lo = fa.deg;
                    victim = i;
                };
            } // else: pre-settle deg/r are 0 — evict the oldest (index 0) instead of a meaningless argmin
            self.evictAt(victim);
        }
        const text = self.gpa.dupe(u8, line) catch return;
        const stems = stemHashes(self.gpa, line);
        if (stems.len == 0) {
            self.gpa.free(text);
            return;
        }
        self.seen.put(self.gpa, key, {}) catch {};
        self.facts.append(self.gpa, .{ .text = text, .stems = stems }) catch {
            self.gpa.free(text);
            self.gpa.free(stems);
            return;
        };
        self.deg_dirty = true;
    }

    /// Fold a newline-joined recall block into the field via observeLine (one dedupe/stem/evict path).
    pub fn ingest(self: *Field, block: []const u8) void {
        var it = std.mem.splitScalar(u8, block, '\n');
        while (it.next()) |raw| self.observeLine(raw);
    }

    /// Seed the field from the store ONCE (the single tolerated subprocess): a wide bulk pull merged in. Called
    /// lazily on a mind's first hyperspace moment, and cheaply re-called every K rounds to absorb facts written
    /// to this scope by other writers (so the warm field never silently diverges from the store).
    pub fn warmFrom(self: *Field, mem: Mem, scope: []const u8, focus: []const u8) void {
        const wide = mem.assoc(scope, focus, 4, 48);
        defer self.gpa.free(wide);
        self.ingest(wide);
        self.warm = true;
    }

    /// Settle the field around a focus: derive the radial hierarchy from link-degree, seed activation from focus
    /// overlap, then spread it a few passes (hub-biased) so multi-hop-relevant facts light up.
    fn settle(self: *Field, focus: []const u64) void {
        const n = self.facts.items;
        if (n.len == 0) return;
        // The O(N^2) hierarchy (degree + radial) only changes when facts are ADDED/EVICTED. On a warm field that
        // is the rare case, so recompute it only when dirty; a steady moment just re-seeds + spreads (cheap).
        if (self.deg_dirty) {
            var maxdeg: f32 = 0.0001;
            for (n, 0..) |*fa, i| {
                var d: f32 = 0;
                for (n, 0..) |fb, j| {
                    if (i == j) continue;
                    d += @floatFromInt(interCount(fa.stems, fb.stems));
                }
                fa.deg = d;
                if (d > maxdeg) maxdeg = d;
            }
            for (n) |*fa| fa.r = 1.0 - (fa.deg / maxdeg); // hubs -> center, leaves -> boundary
            self.deg_dirty = false;
        }
        var maxact: f32 = 0.0001;
        for (n) |*fa| {
            const s: f32 = @floatFromInt(interCount(fa.stems, focus));
            fa.act = s;
            if (s > maxact) maxact = s;
        }
        for (n) |*fa| fa.act /= maxact;

        const tmp = self.gpa.alloc(f32, n.len) catch return;
        defer self.gpa.free(tmp);
        var pass: u32 = 0;
        while (pass < SETTLE_ITERS) : (pass += 1) {
            for (n, 0..) |fa, i| {
                var inflow: f32 = 0;
                for (n, 0..) |fb, j| {
                    if (i == j) continue;
                    const sim: f32 = @floatFromInt(interCount(fa.stems, fb.stems));
                    if (sim == 0) continue;
                    const hub_bias = 1.0 + (1.0 - fb.r) * 0.5; // general facts broadcast a little stronger
                    inflow += fb.act * sim * hub_bias / (fb.deg + 1.0);
                }
                tmp[i] = 0.5 * fa.act + 0.5 * inflow;
            }
            var mx: f32 = 0.0001;
            for (tmp) |v| if (v > mx) {
                mx = v;
            };
            for (n, 0..) |*fa, i| fa.act = tmp[i] / mx;
        }
        self.settled = true; // deg/r now meaningful -> focus-independent eviction may use them
    }

    /// Pack the settled field densely into `budget` bytes: rank by activation (+ a skeleton boost), greedily fill
    /// while dropping near-duplicates. Returns a newline-joined block; caller owns it.
    pub fn pack(self: *Field, focus_text: []const u8, budget: usize) []u8 {
        const fstems = stemHashes(self.gpa, focus_text);
        defer self.gpa.free(fstems);
        self.settle(fstems);
        const n = self.facts.items;
        if (n.len == 0) return dupEmpty(self.gpa);
        const idx = self.gpa.alloc(usize, n.len) catch return dupEmpty(self.gpa);
        defer self.gpa.free(idx);
        for (idx, 0..) |*p, i| p.* = i;
        std.mem.sort(usize, idx, @as([]const Fact, n), packLess);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        var picked: std.ArrayListUnmanaged(usize) = .empty;
        defer picked.deinit(self.gpa);
        for (idx) |i| {
            if (out.items.len + n[i].text.len + 1 > budget) continue; // skip, keep trying smaller facts
            var dup = false;
            for (picked.items) |pj| {
                const inter: f32 = @floatFromInt(interCount(n[i].stems, n[pj].stems));
                const denom: f32 = @floatFromInt(@min(n[i].stems.len, n[pj].stems.len));
                if (denom > 0 and inter / denom > 0.8) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            out.appendSlice(self.gpa, n[i].text) catch {};
            out.append(self.gpa, '\n') catch {};
            picked.append(self.gpa, i) catch {};
            if (out.items.len >= budget) break;
        }
        return out.toOwnedSlice(self.gpa) catch dupEmpty(self.gpa);
    }
};

/// Drop-in replacement for `mem.assoc(scope, focus, 4, 8)` + clip: pull a WIDE candidate set once, settle it
/// in-process around the focus, and return a DENSE, hierarchy-aware pack within `budget`. Caller owns the result.
pub fn recall(gpa: std.mem.Allocator, mem: Mem, scope: []const u8, focus: []const u8, budget: usize) []u8 {
    var field = Field.init(gpa);
    defer field.deinit();
    const wide = mem.assoc(scope, focus, 4, 48); // one bulk pull
    defer gpa.free(wide);
    field.ingest(wide);
    return field.pack(focus, budget);
}

/// As `recall`, but ALSO folds the shared hive knowledge into the same field before settling, so cross-scope
/// links route grounding the flat per-scope clips would miss. Used when the caller wants a single unified pack.
pub fn recallUnified(gpa: std.mem.Allocator, mem: Mem, scope: []const u8, hive_scope: []const u8, focus: []const u8, budget: usize) []u8 {
    var field = Field.init(gpa);
    defer field.deinit();
    const own = mem.assoc(scope, focus, 4, 40);
    defer gpa.free(own);
    field.ingest(own);
    const hive = mem.assoc(hive_scope, focus, 2, 24);
    defer gpa.free(hive);
    field.ingest(hive);
    return field.pack(focus, budget);
}

test "hyperspace settles multi-hop relevance and drops noise" {
    const gpa = std.testing.allocator;
    var f = Field.init(gpa);
    defer f.deinit();
    f.ingest(
        \\EmberOak is a specialty coffee roaster founded in Portland
        \\Portland has a historic roasting district along the river
        \\The roasting district hosts a monthly coffee festival each spring
        \\Quantum chromodynamics describes the strong nuclear force between quarks
        \\Bananas are a reliable dietary source of potassium and fiber
    );
    // focus mentions EmberOak+coffee; Portland/district are reached only by multi-hop links, not by the words.
    const dense = f.pack("EmberOak coffee sourcing", 600);
    defer gpa.free(dense);
    try std.testing.expect(std.mem.indexOf(u8, dense, "EmberOak") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense, "Portland") != null);
    // the coffee cluster must outrank the unrelated physics/nutrition facts: EmberOak appears before quarks.
    const pe = std.mem.indexOf(u8, dense, "EmberOak") orelse dense.len;
    const pq = std.mem.indexOf(u8, dense, "quarks") orelse dense.len;
    try std.testing.expect(pe < pq);
}

test "warm field grows from an in-process observation and ranks it with zero pull" {
    const gpa = std.testing.allocator;
    var f = Field.init(gpa);
    defer f.deinit();
    f.ingest(
        \\the deploy pipeline builds the veil binary with the zig compiler
        \\the neuron memory engine is compiled once from the rust toolchain
    );
    // a fact the swarm just created in-process — absorbed WITHOUT any assoc/subprocess
    f.observeLine("the landing page needs a header search box wired to the remote auth database");
    const dense = f.pack("header search box remote auth database", 400);
    defer gpa.free(dense);
    try std.testing.expect(std.mem.indexOf(u8, dense, "header search box") != null);
}

test "eviction stays bounded, frees victims, and keeps the dedupe set consistent" {
    const gpa = std.testing.allocator; // the testing allocator fails the test on any leaked victim
    var f = Field.init(gpa);
    defer f.deinit();
    var buf: [96]u8 = undefined;
    var i: usize = 0;
    while (i < DEFAULT_MAX_FACTS + 40) : (i += 1) {
        const line = std.fmt.bufPrint(&buf, "distinct persistent fact number {d} about widgets gadgets and sprockets", .{i}) catch continue;
        f.observeLine(line);
    }
    try std.testing.expect(f.facts.items.len <= DEFAULT_MAX_FACTS);
    try std.testing.expect(f.seen.count() == f.facts.items.len); // evicted keys were removed, no unbounded growth
}
