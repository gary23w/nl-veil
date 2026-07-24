//! Neuron ledger — the metered-AI budget that makes multi-tenant Workers AI safe to deploy (per-user grant + usage).

const std = @import("std");
const Neuron = @import("../worker/neuron/client.zig").Neuron;
const ent = @import("entitlements.zig");
const Plan = ent.Plan;

const PERIOD_SECS: i64 = 30 * 24 * 3600;

const Rec = struct { used: u64 = 0, topup: u64 = 0, period_start: i64 = 0 };

pub const Status = struct { granted: u64, used: u64, balance: i64, period_start: i64 };

pub const NeuronLedger = struct {
    gpa: std.mem.Allocator,
    nb: Neuron,
    mu: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, nb: Neuron) NeuronLedger {
        return .{ .gpa = gpa, .nb = nb };
    }

    fn scopeKey(uid: u64, out: *[24]u8) []const u8 {
        return std.fmt.bufPrint(out, "n_{d}", .{uid}) catch "n_0";
    }

    fn load(self: *NeuronLedger, uid: u64) Rec {
        var sb: [24]u8 = undefined;
        const enc = (self.nb.get(scopeKey(uid, &sb)) catch return .{}) orelse return .{};
        defer self.gpa.free(enc);
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(enc) catch return .{};
        const buf = self.gpa.alloc(u8, n) catch return .{};
        defer self.gpa.free(buf);
        dec.decode(buf, enc) catch return .{};
        const p = std.json.parseFromSlice(Rec, self.gpa, buf, .{ .ignore_unknown_fields = true }) catch return .{};
        defer p.deinit();
        return p.value;
    }

    fn save(self: *NeuronLedger, uid: u64, r: Rec) void {
        const json = std.fmt.allocPrint(self.gpa, "{{\"used\":{d},\"topup\":{d},\"period_start\":{d}}}", .{ r.used, r.topup, r.period_start }) catch return;
        defer self.gpa.free(json);
        const e = std.base64.standard.Encoder;
        const buf = self.gpa.alloc(u8, e.calcSize(json.len)) catch return;
        defer self.gpa.free(buf);
        _ = e.encode(buf, json);
        var sb: [24]u8 = undefined;
        const sc = scopeKey(uid, &sb);
        self.nb.del(sc);
        self.nb.put(sc, buf) catch {};
    }

    fn nowSecs(self: *NeuronLedger) i64 {
        return std.Io.Timestamp.now(self.nb.io, .real).toSeconds();
    }

    fn fresh(self: *NeuronLedger, uid: u64) Rec {
        var r = self.load(uid);
        const t = self.nowSecs();
        if (r.period_start == 0) {
            r.period_start = t;
            self.save(uid, r);
        } else if (t - r.period_start >= PERIOD_SECS) {
            r.used = 0;
            r.period_start = t;
            self.save(uid, r);
        }
        return r;
    }

    pub fn status(self: *NeuronLedger, uid: u64, plan: Plan) Status {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const r = self.fresh(uid);
        // Both stored figures saturate on the way IN (addTopup/charge use `+|`), so both have to be clamped on
        // the way OUT. A plain `+` here overflowed on a maxInt topup and @intCast trapped on anything past the
        // i64 ceiling — a panic inside an httpz handler for a number POST /admin/billing accepts verbatim.
        const granted = ent.monthlyNeuronGrant(plan) +| r.topup;
        const g: i64 = std.math.cast(i64, granted) orelse std.math.maxInt(i64);
        const spent: i64 = std.math.cast(i64, r.used) orelse std.math.maxInt(i64);
        return .{ .granted = granted, .used = r.used, .balance = g - spent, .period_start = r.period_start };
    }

    pub fn hasBalance(self: *NeuronLedger, uid: u64, plan: Plan) bool {
        return self.status(uid, plan).balance > 0;
    }

    pub fn charge(self: *NeuronLedger, uid: u64, neurons: u64) void {
        if (neurons == 0) return;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var r = self.fresh(uid);
        r.used +|= neurons;
        self.save(uid, r);
    }

    pub fn addTopup(self: *NeuronLedger, uid: u64, neurons: u64) void {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var r = self.fresh(uid);
        r.topup +|= neurons;
        self.save(uid, r);
    }
};

pub fn neuronsForModel(model: []const u8, tokens_in: u64, tokens_out: u64) u64 {
    const Rate = struct { in_per_m: u64, out_per_m: u64 };
    const r: Rate = if (std.mem.indexOf(u8, model, "70b") != null or std.mem.indexOf(u8, model, "70B") != null)
        .{ .in_per_m = 26_668, .out_per_m = 204_805 }
    else if (std.mem.indexOf(u8, model, "8b") != null or std.mem.indexOf(u8, model, "8B") != null)
        .{ .in_per_m = 25_608, .out_per_m = 75_147 }
    else if (std.mem.indexOf(u8, model, "coder") != null or std.mem.indexOf(u8, model, "qwen") != null)
        .{ .in_per_m = 60_000, .out_per_m = 90_909 }
    else
        .{ .in_per_m = 40_000, .out_per_m = 120_000 };
    const ni = (tokens_in *| r.in_per_m) / 1_000_000;
    const no = (tokens_out *| r.out_per_m) / 1_000_000;
    return ni +| no;
}

// This ledger is what makes hosted Workers AI safe to hand to strangers: hasBalance() is the gate every
// metered call passes (worker/deploy/service.zig), charge() is the only thing that ever debits it
// (worker/control/supervisor.zig), and addTopup() is reachable from POST /admin/billing with a u64 parsed
// straight out of the request body. The rate table below is mirrored BY HAND in worker/run.zig
// (neuronsForCfModel) for the worker's own usage reporting — if these constants move, that copy moves too.

const builtin = @import("builtin");

test "neuronsForModel: the three Workers AI models the catalog ships each bill at their own posted rate" {
    // Exactly one million tokens on one side, so each assertion IS the per-million constant.
    const cf70 = "@cf/meta/llama-3.3-70b-instruct-fp8-fast"; // modelcfg.defaults.cf_model
    try std.testing.expectEqual(@as(u64, 26_668), neuronsForModel(cf70, 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 204_805), neuronsForModel(cf70, 0, 1_000_000));
    try std.testing.expectEqual(@as(u64, 26_668 + 204_805), neuronsForModel(cf70, 1_000_000, 1_000_000));

    // The 70b id also carries "fp8" and the qwen id carries "32b"; neither may be mistaken for the 8b tier,
    // which is what these exact numbers (rather than the 8b row's) pin.
    const cf8 = "@cf/meta/llama-3.1-8b-instruct";
    try std.testing.expectEqual(@as(u64, 25_608), neuronsForModel(cf8, 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 75_147), neuronsForModel(cf8, 0, 1_000_000));

    const cfq = "@cf/qwen/qwen2.5-coder-32b-instruct";
    try std.testing.expectEqual(@as(u64, 60_000), neuronsForModel(cfq, 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 90_909), neuronsForModel(cfq, 0, 1_000_000));
}

test "neuronsForModel: family matching is first-match-wins, and only the parameter-count marker is case-tolerant" {
    // Position in the if-chain is the whole tie-break rule: a qwen coder at 70b bills as 70b, not as coder.
    try std.testing.expectEqual(@as(u64, 26_668), neuronsForModel("@cf/qwen/qwen2.5-coder-70b-instruct", 1_000_000, 0));
    // …and 8b likewise outranks coder/qwen, for the same reason.
    try std.testing.expectEqual(@as(u64, 25_608), neuronsForModel("@cf/qwen/qwen2.5-coder-8b-instruct", 1_000_000, 0));

    // Both spellings of the size marker are searched for explicitly, so case does not change the bill.
    try std.testing.expectEqual(@as(u64, 26_668), neuronsForModel("Llama-3.3-70B-Instruct", 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 25_608), neuronsForModel("Llama-3.1-8B-Instruct", 1_000_000, 0));

    // "coder"/"qwen" are matched LOWERCASE ONLY, so a capitalised vendor spelling drops to the default row
    // (40k in / 120k out) instead of the qwen row (60k / 90.9k) — cheaper on input, dearer on output. Pinned
    // as the behaviour that ships: every id in the catalog is lowercase, and changing it changes real bills.
    try std.testing.expectEqual(@as(u64, 40_000), neuronsForModel("Qwen2.5-Coder-32B-Instruct", 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 120_000), neuronsForModel("Qwen2.5-Coder-32B-Instruct", 0, 1_000_000));
}

test "neuronsForModel: an unknown or empty model bills at the default rate rather than going free" {
    try std.testing.expectEqual(@as(u64, 40_000), neuronsForModel("", 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 120_000), neuronsForModel("", 0, 1_000_000));
    try std.testing.expectEqual(@as(u64, 40_000 + 120_000), neuronsForModel("some-model-nobody-has-priced-yet", 1_000_000, 1_000_000));
    // An unpriced id is never a free ride: it costs strictly more than the cheapest family on both sides, so
    // a typo (or a model added to the catalog before its row is added here) cannot be used to run for nothing.
    try std.testing.expect(neuronsForModel("unknown", 1_000_000, 0) > neuronsForModel("@cf/meta/llama-3.1-8b-instruct", 1_000_000, 0));
    try std.testing.expect(neuronsForModel("unknown", 0, 1_000_000) > neuronsForModel("@cf/meta/llama-3.1-8b-instruct", 0, 1_000_000));
}

test "neuronsForModel: the per-million rates truncate, and the two halves truncate independently" {
    // Default row, input side: 40_000 per million → 25 tokens is the first that costs a whole neuron.
    try std.testing.expectEqual(@as(u64, 0), neuronsForModel("unknown", 24, 0));
    try std.testing.expectEqual(@as(u64, 1), neuronsForModel("unknown", 25, 0));
    // Output side: 120_000 per million → 9 tokens.
    try std.testing.expectEqual(@as(u64, 0), neuronsForModel("unknown", 0, 8));
    try std.testing.expectEqual(@as(u64, 1), neuronsForModel("unknown", 0, 9));

    // The halves are floored SEPARATELY before they are added, so a call whose combined cost is a full neuron
    // (24×40k + 8×120k = 1.92M) still bills zero. Tiny turns are free by rounding — which is why a chatty free
    // account can outlive its grant, and why charge() must never be handed a per-token figure instead.
    try std.testing.expectEqual(@as(u64, 0), neuronsForModel("unknown", 24, 8));
    try std.testing.expectEqual(@as(u64, 0), neuronsForModel("unknown", 0, 0));
}

test "neuronsForModel: an absurd token count saturates instead of overflowing" {
    const max64 = std.math.maxInt(u64);
    const half = max64 / 1_000_000; // each side pins at maxInt(u64) BEFORE the divide
    // A garbage usage figure from a provider must produce a finite (if enormous) bill, not a trap inside the
    // charge path — the `*|` and `+|` here are load bearing.
    try std.testing.expectEqual(@as(u64, half), neuronsForModel("@cf/meta/llama-3.3-70b-instruct-fp8-fast", max64, 0));
    try std.testing.expectEqual(@as(u64, half * 2), neuronsForModel("unknown", max64, max64));
}

test "scopeKey: every u64 id formats in full, so two users can never collide on the n_0 fallback" {
    // The buffer is 24 bytes and the widest key is "n_" + 20 digits = 22. Were it ever narrowed, bufPrint
    // would fail and EVERY large id would quietly share the scope "n_0" — one shared budget for all of them.
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("n_0", NeuronLedger.scopeKey(0, &b));
    try std.testing.expectEqualStrings("n_1", NeuronLedger.scopeKey(1, &b));
    try std.testing.expectEqualStrings("n_18446744073709551615", NeuronLedger.scopeKey(std.math.maxInt(u64), &b));
}

const NEURON_BIN = if (builtin.os.tag == .windows) "bin/neuron.exe" else "bin/neuron";

/// The ledger keeps NOTHING in memory — every read and write goes out through the neuron.exe CLI — so the
/// tests below drive the real store against a throwaway db under cwd. If the checkout's binary is not where
/// the test runner can reach it they skip: against a store that silently swallows every write, `used` would
/// read 0 forever and the assertions would only be testing the stub.
const Live = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    root: []const u8,
    dbbuf: [96]u8,
    led: NeuronLedger,

    /// Starts in place: `io` and the db path both point back into this struct, so it must not be copied.
    fn start(self: *Live, root: []const u8) !void {
        self.gpa = std.testing.allocator;
        // The REAL process environ, exactly as main.zig builds it (and as worker/tools.zig's node gate does).
        // `Io.Threaded.init(gpa, .{})` hands spawned children an EMPTY environment, and under `zig build test`
        // — where the runner starts from a Minimal process init — neuron.exe then comes up with no TEMP and no
        // SystemRoot: `export` prints nothing and `observe` fails, straight into save()'s `catch {}`. The
        // ledger would read as permanently empty and these tests would assert against a store that is not there.
        const environ: std.process.Environ = if (builtin.os.tag == .windows)
            .{ .block = .global }
        else
            .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
        self.threaded = std.Io.Threaded.init(self.gpa, .{ .environ = environ });
        self.root = root;
        const io = self.threaded.io();
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
        const db = std.fmt.bufPrint(&self.dbbuf, "{s}/ledger.db", .{root}) catch unreachable;
        self.led = NeuronLedger.init(self.gpa, Neuron.init(self.gpa, io, NEURON_BIN, db));
        self.probe() catch |e| {
            self.stop(); // the caller's `defer stop()` never registers on an error return
            return e;
        };
    }

    /// A real WRITE→READ round trip, not just "the binary spawned". save() swallows store errors by design,
    /// so a neuron.exe that starts but cannot persist would leave every assertion below running against a
    /// permanently-empty ledger — passing or failing for reasons that have nothing to do with this module.
    fn probe(self: *Live) !void {
        const val = "bmxfdmVpbF9sZWRnZXJfcHJvYmVfdmFsdWU";
        self.led.nb.put("nl_probe", val) catch return error.SkipZigTest;
        const got = (self.led.nb.get("nl_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
        defer self.gpa.free(got);
        if (!std.mem.eql(u8, got, val)) return error.SkipZigTest;
    }

    fn stop(self: *Live) void {
        std.Io.Dir.cwd().deleteTree(self.threaded.io(), self.root) catch {};
        self.threaded.deinit();
    }
};

test "ledger: a fresh account is granted its plan's monthly neurons, and charges land against that grant" {
    var h: Live = undefined;
    try h.start("zig-neurons-grant-tmp");
    defer h.stop();
    const L = &h.led;

    const s0 = L.status(11, .free);
    try std.testing.expectEqual(@as(u64, 500_000), s0.granted);
    try std.testing.expectEqual(@as(u64, 0), s0.used);
    try std.testing.expectEqual(@as(i64, 500_000), s0.balance);
    try std.testing.expect(s0.period_start != 0); // the first touch stamps the period: the clock starts on use

    L.charge(11, 1_234);
    L.charge(11, 0); // a zero-cost turn short-circuits before the store is even opened
    L.charge(11, 766);
    const s1 = L.status(11, .free);
    try std.testing.expectEqual(@as(u64, 2_000), s1.used);
    try std.testing.expectEqual(@as(i64, 498_000), s1.balance);
    try std.testing.expectEqual(s0.period_start, s1.period_start); // spending never restarts the period

    // Usage is stored per user; the grant is re-derived from the plan on every read. Upgrading somebody does
    // not rewrite their ledger — the same spend is simply measured against a bigger allowance.
    const s2 = L.status(11, .max);
    try std.testing.expectEqual(@as(u64, 6_000_000), s2.granted);
    try std.testing.expectEqual(@as(u64, 2_000), s2.used);
    try std.testing.expectEqual(@as(i64, 5_998_000), s2.balance);

    // Tenancy: each id owns scope n_<uid>, so one account's spend can never turn up on another's bill.
    try std.testing.expectEqual(@as(u64, 0), L.status(12, .free).used);
    try std.testing.expectEqual(@as(u64, 2_000), L.status(11, .free).used);
}

test "ledger: hasBalance is strictly positive, so spending the last neuron locks the account until a top-up" {
    var h: Live = undefined;
    try h.start("zig-neurons-balance-tmp");
    defer h.stop();
    const L = &h.led;

    try std.testing.expect(L.hasBalance(21, .free));
    L.charge(21, 499_999);
    try std.testing.expect(L.hasBalance(21, .free)); // one neuron left is still a balance
    L.charge(21, 1);
    try std.testing.expectEqual(@as(i64, 0), L.status(21, .free).balance);
    try std.testing.expect(!L.hasBalance(21, .free)); // …zero is not: the gate is `> 0`, not `>= 0`

    // The balance is signed on purpose. A turn that overshoots what was left records the debt instead of
    // wrapping a u64 subtraction around into a fortune.
    L.charge(21, 10_000);
    try std.testing.expectEqual(@as(i64, -10_000), L.status(21, .free).balance);
    try std.testing.expect(!L.hasBalance(21, .free));

    // A top-up lands on the GRANT side, so it has to clear that debt before it buys anything.
    L.addTopup(21, 10_000);
    try std.testing.expectEqual(@as(i64, 0), L.status(21, .free).balance);
    try std.testing.expect(!L.hasBalance(21, .free));
    L.addTopup(21, 1);
    try std.testing.expect(L.hasBalance(21, .free));
    try std.testing.expectEqual(@as(u64, 510_001), L.status(21, .free).granted); // grant = plan + topups
}

test "ledger: usage resets once the period is a full PERIOD_SECS old, and a top-up survives the reset" {
    var h: Live = undefined;
    try h.start("zig-neurons-period-tmp");
    defer h.stop();
    const L = &h.led;

    // Waiting 30 days is not a test, so the period is aged by writing the record the ledger itself would have
    // written. Two minutes of slack on the "not yet" side keeps it immune to the wall clock ticking during the
    // subprocess round trips below; the rollover side sits on the exact `>=` boundary, where drift only helps.
    const t = L.nowSecs();
    L.save(31, .{ .used = 400_000, .topup = 250_000, .period_start = t - PERIOD_SECS + 120 });
    const before = L.status(31, .pro);
    try std.testing.expectEqual(@as(u64, 400_000), before.used);
    try std.testing.expectEqual(t - PERIOD_SECS + 120, before.period_start); // still inside: nothing is rewritten
    try std.testing.expectEqual(@as(u64, 1_500_000 + 250_000), before.granted);

    L.save(31, .{ .used = 400_000, .topup = 250_000, .period_start = t - PERIOD_SECS });
    const after = L.status(31, .pro);
    try std.testing.expectEqual(@as(u64, 0), after.used); // exactly one period old → metered usage is forgiven
    try std.testing.expect(after.period_start >= t); // …and the next period starts NOW, not at the old mark
    // The top-up is not part of the period: purchased neurons carry over instead of expiring with the month.
    try std.testing.expectEqual(@as(u64, 1_750_000), after.granted);
    try std.testing.expectEqual(@as(i64, 1_750_000), after.balance);
}

test "ledger: a stored record that will not decode is read as a brand-new account — the meter fails OPEN" {
    var h: Live = undefined;
    try h.start("zig-neurons-corrupt-tmp");
    defer h.stop();
    const L = &h.led;
    const gpa = std.testing.allocator;

    L.charge(41, 250_000);
    try std.testing.expectEqual(@as(u64, 250_000), L.status(41, .free).used);

    var sb: [24]u8 = undefined;
    const sc = NeuronLedger.scopeKey(41, &sb);

    // Bytes that are not base64 at all: load() gives up at calcSizeForSlice and hands back a zero Rec.
    try L.nb.put(sc, "!!!!not-base64-at-all!!!!not-base64-at-all!!!!");
    const s1 = L.status(41, .free);
    try std.testing.expectEqual(@as(u64, 0), s1.used); // every path in load() forgives usage rather than denying
    try std.testing.expectEqual(@as(u64, 500_000), s1.granted);
    try std.testing.expect(L.hasBalance(41, .free));

    // …and the unreadable blob is not merely ignored, it is GONE: fresh() saw period_start == 0 and wrote a
    // clean record straight over it, so a decode hiccup also erases the evidence of what the account spent.
    const raw = (try L.nb.get(sc)).?;
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "!!!!") == null);

    // Same fail-open for base64 that decodes cleanly but is not the Rec JSON.
    const enc = std.base64.standard.Encoder;
    const plain = "this decodes cleanly but it is not json";
    var eb: [64]u8 = undefined;
    try L.nb.put(sc, enc.encode(eb[0..enc.calcSize(plain.len)], plain));
    try std.testing.expectEqual(@as(u64, 0), L.status(41, .free).used);
}

test "ledger: a saturating top-up or spend clamps the reported balance instead of trapping" {
    var h: Live = undefined;
    try h.start("zig-neurons-saturate-tmp");
    defer h.stop();
    const L = &h.led;
    const max64 = std.math.maxInt(u64);

    // addTopup saturates (`+|`), and POST /admin/billing parses `topup` straight out of the body as a u64
    // (worker/deploy/service.zig), so an admin fat-finger can genuinely park maxInt(u64) in the record.
    // status() then has to render that as an i64: the grant clamps at the i64 ceiling rather than overflowing.
    L.addTopup(51, max64);
    L.addTopup(51, max64);
    const s = L.status(51, .free);
    try std.testing.expectEqual(@as(u64, max64), s.granted);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), s.balance);
    try std.testing.expect(L.hasBalance(51, .free));

    // The same clamp on the spend side: charge() saturates `used`, so the debit can reach maxInt(u64) too.
    L.charge(51, max64);
    L.charge(51, max64);
    const s2 = L.status(51, .free);
    try std.testing.expectEqual(@as(u64, max64), s2.used);
    try std.testing.expectEqual(@as(i64, 0), s2.balance); // both sides clamp to the same ceiling
    try std.testing.expect(!L.hasBalance(51, .free));
}
