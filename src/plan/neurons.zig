//! Neuron ledger — the metered-AI budget that makes multi-tenant Workers AI safe to deploy (per-user grant + usage).

const std = @import("std");
const Neuron = @import("../worker/neuron/client.zig").Neuron;
const ent = @import("entitlements.zig");
const Plan = ent.Plan;

const PERIOD_SECS: i64 = 30 * 24 * 3600;

// Top-up IDs live in the same stored value as the balance. A separate marker
// would leave another ambiguous boundary between the credit and its marker.
const MAX_TOPUP_OPS = 128;
const MAX_TOPUP_ID = 64;
const TOPUP_RETRY_SECS: i64 = 90 * 24 * 3600;
const TopupOp = struct { id: [MAX_TOPUP_ID]u8 = undefined, len: u8 = 0, neurons: u64 = 0 };
const StoredTopupOp = struct { id: []const u8, neurons: u64 };
const RUN_ID_LEN = 17;
const StoredPendingRun = struct { id: []const u8, target: u64 };
const Stored = struct {
    used: u64,
    topup: u64,
    period_start: i64,
    topup_ops: []const StoredTopupOp = &.{},
    pending_run: ?StoredPendingRun = null,
};
const Rec = struct {
    used: u64 = 0,
    topup: u64 = 0,
    period_start: i64 = 0,
    topup_ops: [MAX_TOPUP_OPS]TopupOp = undefined,
    topup_ops_len: usize = 0,
    pending_run_id: [RUN_ID_LEN]u8 = undefined,
    pending_run_target: u64 = 0,
    has_pending_run: bool = false,
};

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

    fn validRunId(id: []const u8) bool {
        if (id.len != RUN_ID_LEN or (id[0] != 'r' and id[0] != 'l')) return false;
        for (id[1..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
        return true;
    }

    fn runScopeKey(uid: u64, id: []const u8, out: *[48]u8) ![]const u8 {
        if (!validRunId(id)) return error.InvalidRunId;
        return std.fmt.bufPrint(out, "nr_{d}_{s}", .{ uid, id });
    }

    /// IDs carry their issue time so an expired retry can be rejected even
    /// after its marker is pruned. Format: t<unix-seconds>_<unique nonce>.
    fn topupIdTime(id: []const u8) ?i64 {
        if (id.len < 20 or id.len > MAX_TOPUP_ID or id[0] != 't') return null;
        const sep = std.mem.indexOfScalar(u8, id, '_') orelse return null;
        if (sep < 10 or sep > 13 or id.len - sep - 1 < 8) return null;
        for (id[1..sep]) |c| if (!std.ascii.isDigit(c)) return null;
        for (id[sep + 1 ..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
        return std.fmt.parseInt(i64, id[1..sep], 10) catch null;
    }

    pub fn validTopupIdAt(id: []const u8, now: i64) bool {
        const issued = topupIdTime(id) orelse return false;
        return issued >= now - TOPUP_RETRY_SECS and issued <= now + 300;
    }

    fn load(self: *NeuronLedger, uid: u64) !Rec {
        var sb: [24]u8 = undefined;
        const scope = scopeKey(uid, &sb);
        const enc = (try self.nb.get(scope)) orelse {
            // Neuron lists forgotten scopes even when export is empty. A fresh account
            // has no scope; an existing empty scope is lost accounting state.
            const scopes = try self.nb.scopes("n_");
            defer {
                for (scopes) |s| self.gpa.free(s);
                self.gpa.free(scopes);
            }
            for (scopes) |s| if (std.mem.eql(u8, s, scope)) return error.MissingLedgerRecord;
            return .{};
        };
        defer self.gpa.free(enc);
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(enc) catch return error.InvalidLedgerRecord;
        const buf = try self.gpa.alloc(u8, n);
        defer self.gpa.free(buf);
        dec.decode(buf, enc) catch return error.InvalidLedgerRecord;
        const p = std.json.parseFromSlice(Stored, self.gpa, buf, .{ .ignore_unknown_fields = true }) catch return error.InvalidLedgerRecord;
        defer p.deinit();
        if (p.value.period_start <= 0 or p.value.topup_ops.len > MAX_TOPUP_OPS) return error.InvalidLedgerRecord;
        var r: Rec = .{
            .used = p.value.used,
            .topup = p.value.topup,
            .period_start = p.value.period_start,
        };
        for (p.value.topup_ops) |op| {
            if (topupIdTime(op.id) == null or op.neurons == 0) return error.InvalidLedgerRecord;
            for (r.topup_ops[0..r.topup_ops_len]) |prev| {
                if (std.mem.eql(u8, prev.id[0..prev.len], op.id)) return error.InvalidLedgerRecord;
            }
            const dst = &r.topup_ops[r.topup_ops_len];
            @memcpy(dst.id[0..op.id.len], op.id);
            dst.len = @intCast(op.id.len);
            dst.neurons = op.neurons;
            r.topup_ops_len += 1;
        }
        if (p.value.pending_run) |pending| {
            if (!validRunId(pending.id)) return error.InvalidLedgerRecord;
            @memcpy(&r.pending_run_id, pending.id);
            r.pending_run_target = pending.target;
            r.has_pending_run = true;
        }
        return r;
    }

    fn save(self: *NeuronLedger, uid: u64, r: Rec) !void {
        var ops: [MAX_TOPUP_OPS]StoredTopupOp = undefined;
        for (0..r.topup_ops_len) |i| {
            ops[i] = .{ .id = r.topup_ops[i].id[0..r.topup_ops[i].len], .neurons = r.topup_ops[i].neurons };
        }
        const json = try std.json.Stringify.valueAlloc(self.gpa, Stored{
            .used = r.used,
            .topup = r.topup,
            .period_start = r.period_start,
            .topup_ops = ops[0..r.topup_ops_len],
            .pending_run = if (r.has_pending_run) .{ .id = &r.pending_run_id, .target = r.pending_run_target } else null,
        }, .{});
        defer self.gpa.free(json);
        const e = std.base64.standard.Encoder;
        const buf = try self.gpa.alloc(u8, e.calcSize(json.len));
        defer self.gpa.free(buf);
        _ = e.encode(buf, json);
        var sb: [24]u8 = undefined;
        const sc = scopeKey(uid, &sb);
        try self.nb.put(sc, buf);
        const got = (try self.nb.get(sc)) orelse return error.LedgerRecordNotPersisted;
        defer self.gpa.free(got);
        if (!std.mem.eql(u8, got, buf)) return error.LedgerRecordNotPersisted;
    }

    fn nowSecs(self: *NeuronLedger) i64 {
        return std.Io.Timestamp.now(self.nb.io, .real).toSeconds();
    }

    fn fresh(self: *NeuronLedger, uid: u64) !Rec {
        var r = try self.load(uid);
        const t = self.nowSecs();
        if (r.period_start == 0) {
            r.period_start = t;
            try self.save(uid, r);
        } else if (t - r.period_start >= PERIOD_SECS) {
            r.used = 0;
            r.period_start = t;
            try self.save(uid, r);
        }
        return r;
    }

    pub fn status(self: *NeuronLedger, uid: u64, plan: Plan) !Status {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const r = try self.fresh(uid);
        // Both stored figures saturate on the way IN (addTopup/charge use `+|`), so both have to be clamped on
        // the way OUT. A plain `+` here overflowed on a maxInt topup and @intCast trapped on anything past the
        // i64 ceiling — a panic inside an httpz handler for a number POST /admin/billing accepts verbatim.
        const granted = ent.monthlyNeuronGrant(plan) +| r.topup;
        const g: i64 = std.math.cast(i64, granted) orelse std.math.maxInt(i64);
        const spent: i64 = std.math.cast(i64, r.used) orelse std.math.maxInt(i64);
        return .{ .granted = granted, .used = r.used, .balance = g - spent, .period_start = r.period_start };
    }

    pub fn hasBalance(self: *NeuronLedger, uid: u64, plan: Plan) !bool {
        return (try self.status(uid, plan)).balance > 0;
    }

    pub fn charge(self: *NeuronLedger, uid: u64, neurons: u64) !void {
        if (neurons == 0) return;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var r = try self.fresh(uid);
        r.used +|= neurons;
        try self.save(uid, r);
    }

    /// A run cursor is separate so accounts can have an unbounded number of
    /// historical runs. The pending marker in n_<uid> makes the two writes
    /// recoverable: the debit and intent are always saved together first.
    fn loadRun(self: *NeuronLedger, uid: u64, id: []const u8) !?u64 {
        var sb: [48]u8 = undefined;
        const sc = try runScopeKey(uid, id, &sb);
        const enc = (try self.nb.get(sc)) orelse {
            const scopes = try self.nb.scopes("nr_");
            defer {
                for (scopes) |s| self.gpa.free(s);
                self.gpa.free(scopes);
            }
            for (scopes) |s| if (std.mem.eql(u8, s, sc)) return error.MissingRunRecord;
            return null;
        };
        defer self.gpa.free(enc);
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(enc) catch return error.InvalidRunRecord;
        const buf = try self.gpa.alloc(u8, n);
        defer self.gpa.free(buf);
        dec.decode(buf, enc) catch return error.InvalidRunRecord;
        const p = std.json.parseFromSlice(struct { charged: u64 }, self.gpa, buf, .{ .ignore_unknown_fields = true }) catch return error.InvalidRunRecord;
        defer p.deinit();
        return p.value.charged;
    }

    fn saveRun(self: *NeuronLedger, uid: u64, id: []const u8, charged: u64) !void {
        var sb: [48]u8 = undefined;
        const sc = try runScopeKey(uid, id, &sb);
        const json = try std.json.Stringify.valueAlloc(self.gpa, .{ .charged = charged }, .{});
        defer self.gpa.free(json);
        const e = std.base64.standard.Encoder;
        const buf = try self.gpa.alloc(u8, e.calcSize(json.len));
        defer self.gpa.free(buf);
        _ = e.encode(buf, json);
        try self.nb.put(sc, buf);
        const got = (try self.nb.get(sc)) orelse return error.RunRecordNotPersisted;
        defer self.gpa.free(got);
        if (!std.mem.eql(u8, got, buf)) return error.RunRecordNotPersisted;
    }

    /// Register before launching a new run. For a legacy run first seen after
    /// upgrade, baseline its existing usage: aggregate old debits cannot be
    /// attributed to individual runs after a cold restart.
    pub fn prepareRun(self: *NeuronLedger, uid: u64, id: []const u8, baseline: u64) !void {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        _ = try self.fresh(uid);
        if (try self.loadRun(uid, id) != null) return;
        try self.saveRun(uid, id, baseline);
    }

    fn settlePending(self: *NeuronLedger, uid: u64, r: *Rec) !void {
        if (!r.has_pending_run) return;
        const id = &r.pending_run_id;
        const prior = (try self.loadRun(uid, id)) orelse return error.MissingRunRecord;
        if (prior > r.pending_run_target) return error.RunCounterConflict;
        if (prior < r.pending_run_target) try self.saveRun(uid, id, r.pending_run_target);
        r.has_pending_run = false;
        try self.save(uid, r.*);
    }

    /// Charge a cumulative sample. Retrying the same sample after any failed
    /// confirmation (including with a new server process) cannot add it twice.
    pub fn chargeRun(self: *NeuronLedger, uid: u64, id: []const u8, cumulative: u64) !void {
        if (!validRunId(id)) return error.InvalidRunId;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var r = try self.fresh(uid);
        try self.settlePending(uid, &r);
        const prior = (try self.loadRun(uid, id)) orelse return error.UnregisteredRun;
        if (cumulative < prior) return error.RunCounterRollback;
        if (cumulative == prior) return;
        r.used +|= cumulative - prior;
        @memcpy(&r.pending_run_id, id);
        r.pending_run_target = cumulative;
        r.has_pending_run = true;
        try self.save(uid, r);
        try self.settlePending(uid, &r);
    }

    /// A retry with the same ID is successful without adding credit again, even
    /// when the first write committed but its confirming read failed.
    pub fn addTopup(self: *NeuronLedger, uid: u64, neurons: u64, operation_id: []const u8) !void {
        const now = self.nowSecs();
        if (!validTopupIdAt(operation_id, now)) return error.InvalidTopupId;
        if (neurons == 0) return error.InvalidTopupAmount;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var r = try self.fresh(uid);
        // The timestamp is in the ID itself, so removing an old marker cannot
        // turn a late retry into a new grant: old IDs fail validation above.
        var kept: usize = 0;
        for (r.topup_ops[0..r.topup_ops_len]) |op| {
            if (topupIdTime(op.id[0..op.len]).? < now - TOPUP_RETRY_SECS) continue;
            r.topup_ops[kept] = op;
            kept += 1;
        }
        r.topup_ops_len = kept;
        for (r.topup_ops[0..r.topup_ops_len]) |op| {
            if (!std.mem.eql(u8, op.id[0..op.len], operation_id)) continue;
            if (op.neurons != neurons) return error.TopupOperationConflict;
            return;
        }
        if (r.topup_ops_len == MAX_TOPUP_OPS) return error.TopupHistoryFull;
        const op = &r.topup_ops[r.topup_ops_len];
        @memcpy(op.id[0..operation_id.len], operation_id);
        op.len = @intCast(operation_id.len);
        op.neurons = neurons;
        r.topup_ops_len += 1;
        r.topup +|= neurons;
        try self.save(uid, r);
    }
};

pub fn neuronsForModel(model: []const u8, tokens_in: u64, tokens_out: u64) u64 {
    const Rate = struct { in_per_m: u64, out_per_m: u64 };
    // Case-folded ONCE, then matched with lowercase needles. The parameter-count markers were
    // already spelled both ways ("70b"/"70B"), but the family markers were not — so a vendor
    // publishing `Qwen2.5-Coder-32B-Instruct` (as they do) missed the coder row and silently fell
    // to the default: cheaper on input, DEARER on output, against the table's plain intent. Every
    // id shipped in models.yaml is lowercase, so no bill changes today; this is the case that was
    // one vendor rename away. MIRRORED in worker/run.zig — a test asserts the two agree.
    var lb: [256]u8 = undefined;
    const n = @min(model.len, lb.len);
    for (model[0..n], 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const m = lb[0..n];
    const r: Rate = if (std.mem.indexOf(u8, m, "70b") != null)
        .{ .in_per_m = 26_668, .out_per_m = 204_805 }
    else if (std.mem.indexOf(u8, m, "8b") != null)
        .{ .in_per_m = 25_608, .out_per_m = 75_147 }
    else if (std.mem.indexOf(u8, m, "coder") != null or std.mem.indexOf(u8, m, "qwen") != null)
        .{ .in_per_m = 60_000, .out_per_m = 90_909 }
    else
        .{ .in_per_m = 40_000, .out_per_m = 120_000 };
    const ni = (tokens_in *| r.in_per_m) / 1_000_000;
    const no = (tokens_out *| r.out_per_m) / 1_000_000;
    return ni +| no;
}

// This ledger is what makes hosted Workers AI safe to hand to strangers: hasBalance() is the gate every
// metered call passes (worker/deploy/service.zig), chargeRun() debits worker usage
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

test "neuronsForModel: family matching is first-match-wins, and case never changes the bill" {
    // Position in the if-chain is the whole tie-break rule: a qwen coder at 70b bills as 70b, not as coder.
    try std.testing.expectEqual(@as(u64, 26_668), neuronsForModel("@cf/qwen/qwen2.5-coder-70b-instruct", 1_000_000, 0));
    // …and 8b likewise outranks coder/qwen, for the same reason.
    try std.testing.expectEqual(@as(u64, 25_608), neuronsForModel("@cf/qwen/qwen2.5-coder-8b-instruct", 1_000_000, 0));

    // The size markers were always case-tolerant.
    try std.testing.expectEqual(@as(u64, 26_668), neuronsForModel("Llama-3.3-70B-Instruct", 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 25_608), neuronsForModel("Llama-3.1-8B-Instruct", 1_000_000, 0));

    // …and the FAMILY markers are now too. A capitalised vendor spelling used to miss the qwen row and fall
    // to the default (40k in / 120k out) — cheaper on input, DEARER on output — which no reading of this
    // table intends. Every id in models.yaml is lowercase, so no bill changes today; this closes the case
    // that was one vendor rename away.
    try std.testing.expectEqual(@as(u64, 60_000), neuronsForModel("Qwen2.5-Coder-32B-Instruct", 1_000_000, 0));
    try std.testing.expectEqual(@as(u64, 90_909), neuronsForModel("Qwen2.5-Coder-32B-Instruct", 0, 1_000_000));
    // Mixed case anywhere in the id lands on the same row as its lowercase twin.
    try std.testing.expectEqual(
        neuronsForModel("@cf/qwen/qwen2.5-coder-32b-instruct", 1_000_000, 1_000_000),
        neuronsForModel("@CF/QWEN/QWEN2.5-CODER-32B-INSTRUCT", 1_000_000, 1_000_000),
    );
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

    /// A real WRITE→READ round trip, not just "the binary spawned". The live tests
    /// must first prove that this datastore can retain the ledger values they assert.
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

fn testTopupId(ledger: *NeuronLedger, suffix: []const u8, out: *[96]u8) []const u8 {
    return std.fmt.bufPrint(out, "t{d}_{s}", .{ ledger.nowSecs(), suffix }) catch unreachable;
}

test "ledger: a fresh account is granted its plan's monthly neurons, and charges land against that grant" {
    var h: Live = undefined;
    try h.start("zig-neurons-grant-tmp");
    defer h.stop();
    const L = &h.led;

    const s0 = try L.status(11, .free);
    try std.testing.expectEqual(@as(u64, 500_000), s0.granted);
    try std.testing.expectEqual(@as(u64, 0), s0.used);
    try std.testing.expectEqual(@as(i64, 500_000), s0.balance);
    try std.testing.expect(s0.period_start != 0); // the first touch stamps the period: the clock starts on use

    try L.charge(11, 1_234);
    try L.charge(11, 0); // a zero-cost turn short-circuits before the store is even opened
    try L.charge(11, 766);
    const s1 = try L.status(11, .free);
    try std.testing.expectEqual(@as(u64, 2_000), s1.used);
    try std.testing.expectEqual(@as(i64, 498_000), s1.balance);
    try std.testing.expectEqual(s0.period_start, s1.period_start); // spending never restarts the period

    // Usage is stored per user; the grant is re-derived from the plan on every read. Upgrading somebody does
    // not rewrite their ledger — the same spend is simply measured against a bigger allowance.
    const s2 = try L.status(11, .max);
    try std.testing.expectEqual(@as(u64, 6_000_000), s2.granted);
    try std.testing.expectEqual(@as(u64, 2_000), s2.used);
    try std.testing.expectEqual(@as(i64, 5_998_000), s2.balance);

    // Tenancy: each id owns scope n_<uid>, so one account's spend can never turn up on another's bill.
    try std.testing.expectEqual(@as(u64, 0), (try L.status(12, .free)).used);
    try std.testing.expectEqual(@as(u64, 2_000), (try L.status(11, .free)).used);
}

test "ledger: hasBalance is strictly positive, so spending the last neuron locks the account until a top-up" {
    var h: Live = undefined;
    try h.start("zig-neurons-balance-tmp");
    defer h.stop();
    const L = &h.led;

    try std.testing.expect(try L.hasBalance(21, .free));
    try L.charge(21, 499_999);
    try std.testing.expect(try L.hasBalance(21, .free)); // one neuron left is still a balance
    try L.charge(21, 1);
    try std.testing.expectEqual(@as(i64, 0), (try L.status(21, .free)).balance);
    try std.testing.expect(!(try L.hasBalance(21, .free))); // …zero is not: the gate is `> 0`, not `>= 0`

    // The balance is signed on purpose. A turn that overshoots what was left records the debt instead of
    // wrapping a u64 subtraction around into a fortune.
    try L.charge(21, 10_000);
    try std.testing.expectEqual(@as(i64, -10_000), (try L.status(21, .free)).balance);
    try std.testing.expect(!(try L.hasBalance(21, .free)));

    // A top-up lands on the GRANT side, so it has to clear that debt before it buys anything.
    var idbuf: [96]u8 = undefined;
    try L.addTopup(21, 10_000, testTopupId(L, "balance-credit-0001", &idbuf));
    try std.testing.expectEqual(@as(i64, 0), (try L.status(21, .free)).balance);
    try std.testing.expect(!(try L.hasBalance(21, .free)));
    try L.addTopup(21, 1, testTopupId(L, "balance-credit-0002", &idbuf));
    try std.testing.expect(try L.hasBalance(21, .free));
    try std.testing.expectEqual(@as(u64, 510_001), (try L.status(21, .free)).granted); // grant = plan + topups
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
    try L.save(31, .{ .used = 400_000, .topup = 250_000, .period_start = t - PERIOD_SECS + 120 });
    const before = try L.status(31, .pro);
    try std.testing.expectEqual(@as(u64, 400_000), before.used);
    try std.testing.expectEqual(t - PERIOD_SECS + 120, before.period_start); // still inside: nothing is rewritten
    try std.testing.expectEqual(@as(u64, 1_500_000 + 250_000), before.granted);

    try L.save(31, .{ .used = 400_000, .topup = 250_000, .period_start = t - PERIOD_SECS });
    const after = try L.status(31, .pro);
    try std.testing.expectEqual(@as(u64, 0), after.used); // exactly one period old → metered usage is forgiven
    try std.testing.expect(after.period_start >= t); // …and the next period starts NOW, not at the old mark
    // The top-up is not part of the period: purchased neurons carry over instead of expiring with the month.
    try std.testing.expectEqual(@as(u64, 1_750_000), after.granted);
    try std.testing.expectEqual(@as(i64, 1_750_000), after.balance);
}

test "ledger: corrupt stored usage fails closed without erasing the evidence" {
    var h: Live = undefined;
    try h.start("zig-neurons-corrupt-tmp");
    defer h.stop();
    const L = &h.led;
    const gpa = std.testing.allocator;

    try L.charge(41, 250_000);
    try std.testing.expectEqual(@as(u64, 250_000), (try L.status(41, .free)).used);

    var sb: [24]u8 = undefined;
    const sc = NeuronLedger.scopeKey(41, &sb);

    // Bytes that are not base64 must not be treated as a zero-usage account.
    const corrupt = "!!!!not-base64-at-all!!!!not-base64-at-all!!!!";
    try L.nb.put(sc, corrupt);
    try std.testing.expectError(error.InvalidLedgerRecord, L.status(41, .free));
    try std.testing.expectError(error.InvalidLedgerRecord, L.hasBalance(41, .free));
    var idbuf: [96]u8 = undefined;
    try std.testing.expectError(error.InvalidLedgerRecord, L.addTopup(41, 1, testTopupId(L, "corrupt-credit-0001", &idbuf)));

    // Rejected reads preserve the original bytes for repair or an audit.
    const raw = (try L.nb.get(sc)).?;
    defer gpa.free(raw);
    try std.testing.expectEqualStrings(corrupt, raw);

    // Same behavior for base64 that decodes cleanly but is not the Rec JSON.
    const enc = std.base64.standard.Encoder;
    const plain = "this decodes cleanly but it is not json";
    var eb: [64]u8 = undefined;
    try L.nb.put(sc, enc.encode(eb[0..enc.calcSize(plain.len)], plain));
    try std.testing.expectError(error.InvalidLedgerRecord, L.status(41, .free));
}

test "ledger: a listed empty export stops balance checks and top-ups" {
    var h: Live = undefined;
    try h.start("zig-neurons-empty-tmp");
    defer h.stop();
    const L = &h.led;
    _ = try L.status(61, .free);
    var sb: [24]u8 = undefined;
    const sc = NeuronLedger.scopeKey(61, &sb);
    try L.nb.delChecked(sc);
    try std.testing.expect((try L.nb.get(sc)) == null);
    try std.testing.expectError(error.MissingLedgerRecord, L.status(61, .free));
    var idbuf: [96]u8 = undefined;
    try std.testing.expectError(error.MissingLedgerRecord, L.addTopup(61, 1_000, testTopupId(L, "missing-credit-0001", &idbuf)));
}

test "ledger: a failed stored write does not acknowledge credit or usage" {
    var h: Live = undefined;
    try h.start("zig-neurons-write-fail-tmp");
    defer h.stop();
    const L = &h.led;
    _ = try L.status(71, .free);
    var sb: [24]u8 = undefined;
    const sc = NeuronLedger.scopeKey(71, &sb);
    var fault: Neuron.TestFault = .{};
    L.nb.test_fault = &fault;
    fault.fail_put_scope_once = sc;
    var idbuf: [96]u8 = undefined;
    try std.testing.expectError(error.TestInjectedWriteFailure, L.addTopup(71, 1_000, testTopupId(L, "write-fail-credit-0001", &idbuf)));
    fault.fail_put_scope_once = sc;
    try std.testing.expectError(error.TestInjectedWriteFailure, L.charge(71, 500));
    const after = try L.status(71, .free);
    try std.testing.expectEqual(@as(u64, 0), after.used);
    try std.testing.expectEqual(@as(u64, 500_000), after.granted);
}

test "ledger: a committed top-up with a failed confirmation is not granted again on retry" {
    var h: Live = undefined;
    try h.start("zig-neurons-topup-retry-tmp");
    defer h.stop();
    const L = &h.led;
    _ = try L.status(72, .free);
    var fault: Neuron.TestFault = .{};
    L.nb.test_fault = &fault;
    fault.fail_get_after_put_scope = "n_72";
    var idbuf: [96]u8 = undefined;
    const id = testTopupId(L, "ambiguous-credit-0001", &idbuf);
    try std.testing.expectError(error.TestInjectedReadFailure, L.addTopup(72, 1_000, id));
    var reopened = NeuronLedger.init(h.gpa, L.nb);
    try reopened.addTopup(72, 1_000, id);
    try std.testing.expectEqual(@as(u64, 501_000), (try reopened.status(72, .free)).granted);
    try std.testing.expectError(error.TopupOperationConflict, reopened.addTopup(72, 2_000, id));
    try reopened.addTopup(72, 500, testTopupId(L, "ambiguous-credit-0002", &idbuf));
    try std.testing.expectEqual(@as(u64, 501_500), (try reopened.status(72, .free)).granted);
}

test "ledger: a committed usage charge with failed confirmation is not billed twice after reopen" {
    var h: Live = undefined;
    try h.start("zig-neurons-usage-retry-tmp");
    defer h.stop();
    const L = &h.led;
    _ = try L.status(75, .free);
    const run_id = "r0123456789abcdef";
    try L.prepareRun(75, run_id, 0);
    var fault: Neuron.TestFault = .{};
    L.nb.test_fault = &fault;
    fault.fail_get_after_put_scope = "n_75";
    try std.testing.expectError(error.TestInjectedReadFailure, L.chargeRun(75, run_id, 500));
    var reopened = NeuronLedger.init(h.gpa, L.nb);
    try reopened.chargeRun(75, run_id, 500);
    try std.testing.expectEqual(@as(u64, 500), (try reopened.status(75, .free)).used);
    try reopened.chargeRun(75, run_id, 750);
    try std.testing.expectEqual(@as(u64, 750), (try reopened.status(75, .free)).used);
}

test "ledger: cursor confirmation failure, period rollover, and legacy baseline keep usage exact" {
    var h: Live = undefined;
    try h.start("zig-neurons-run-cursor-tmp");
    defer h.stop();
    const L = &h.led;
    const id = "r1111111111111111";
    try L.prepareRun(76, id, 0);
    var fault: Neuron.TestFault = .{};
    L.nb.test_fault = &fault;
    fault.fail_get_after_put_scope = "nr_76_r1111111111111111";
    try std.testing.expectError(error.TestInjectedReadFailure, L.chargeRun(76, id, 500));
    var reopened = NeuronLedger.init(h.gpa, L.nb);
    try reopened.chargeRun(76, id, 500);
    try std.testing.expectEqual(@as(u64, 500), (try reopened.status(76, .free)).used);
    var aged = try reopened.load(76);
    aged.period_start = reopened.nowSecs() - PERIOD_SECS;
    try reopened.save(76, aged);
    try std.testing.expectEqual(@as(u64, 0), (try reopened.status(76, .free)).used);
    try reopened.chargeRun(76, id, 500);
    try std.testing.expectEqual(@as(u64, 0), (try reopened.status(76, .free)).used);
    try reopened.chargeRun(76, id, 700);
    try std.testing.expectEqual(@as(u64, 200), (try reopened.status(76, .free)).used);
    try std.testing.expectError(error.RunCounterRollback, reopened.chargeRun(76, id, 600));

    const legacy_id = "l2222222222222222";
    const old: Rec = .{ .used = 42, .period_start = reopened.nowSecs() };
    try reopened.save(77, old);
    try reopened.prepareRun(77, legacy_id, 500);
    try reopened.chargeRun(77, legacy_id, 500);
    try std.testing.expectEqual(@as(u64, 42), (try reopened.status(77, .free)).used);
    try reopened.chargeRun(77, legacy_id, 600);
    try std.testing.expectEqual(@as(u64, 142), (try reopened.status(77, .free)).used);
}

test "ledger: a legacy three-field record retains its credit across keyed top-ups" {
    var h: Live = undefined;
    try h.start("zig-neurons-legacy-topup-tmp");
    defer h.stop();
    const L = &h.led;
    var jbuf: [128]u8 = undefined;
    const json = try std.fmt.bufPrint(&jbuf, "{{\"used\":25,\"topup\":300,\"period_start\":{d}}}", .{L.nowSecs()});
    var bbuf: [256]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    try L.nb.put("n_73", enc.encode(bbuf[0..enc.calcSize(json.len)], json));
    const before = try L.status(73, .free);
    try std.testing.expectEqual(@as(u64, 25), before.used);
    try std.testing.expectEqual(@as(u64, 500_300), before.granted);
    var idbuf: [96]u8 = undefined;
    const id = testTopupId(L, "legacy-credit-0001", &idbuf);
    try L.addTopup(73, 500, id);
    var reopened = NeuronLedger.init(h.gpa, L.nb);
    try reopened.addTopup(73, 500, id);
    const after = try reopened.status(73, .free);
    try std.testing.expectEqual(@as(u64, 25), after.used);
    try std.testing.expectEqual(@as(u64, 500_800), after.granted);
    var aged = try reopened.load(73);
    aged.period_start = reopened.nowSecs() - PERIOD_SECS;
    try reopened.save(73, aged);
    try reopened.addTopup(73, 500, id);
    const rolled = try reopened.status(73, .free);
    try std.testing.expectEqual(@as(u64, 0), rolled.used);
    try std.testing.expectEqual(@as(u64, 500_800), rolled.granted);
}

test "ledger: expired top-up IDs can be pruned but cannot be replayed" {
    var h: Live = undefined;
    try h.start("zig-neurons-topup-expiry-tmp");
    defer h.stop();
    const L = &h.led;
    const now = L.nowSecs();
    var r: Rec = .{ .period_start = now, .topup = MAX_TOPUP_OPS };
    var idbuf: [96]u8 = undefined;
    for (0..MAX_TOPUP_OPS) |i| {
        const old_id = try std.fmt.bufPrint(&idbuf, "t{d}_old-credit-{d}", .{ now - TOPUP_RETRY_SECS - 1, i });
        const op = &r.topup_ops[i];
        @memcpy(op.id[0..old_id.len], old_id);
        op.len = @intCast(old_id.len);
        op.neurons = 1;
        r.topup_ops_len += 1;
    }
    try L.save(74, r);
    const expired_id = try std.fmt.bufPrint(&idbuf, "t{d}_old-credit-0", .{now - TOPUP_RETRY_SECS - 1});
    try std.testing.expectError(error.InvalidTopupId, L.addTopup(74, 1, expired_id));
    const fresh_id = try std.fmt.bufPrint(&idbuf, "t{d}_new-credit-0001", .{now});
    try L.addTopup(74, 1, fresh_id);
    try std.testing.expectEqual(@as(usize, 1), (try L.load(74)).topup_ops_len);
    try std.testing.expectEqual(@as(u64, 500_129), (try L.status(74, .free)).granted);
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
    var idbuf: [96]u8 = undefined;
    try L.addTopup(51, max64, testTopupId(L, "saturate-credit-0001", &idbuf));
    try L.addTopup(51, max64, testTopupId(L, "saturate-credit-0002", &idbuf));
    const s = try L.status(51, .free);
    try std.testing.expectEqual(@as(u64, max64), s.granted);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), s.balance);
    try std.testing.expect(try L.hasBalance(51, .free));

    // The same clamp on the spend side: charge() saturates `used`, so the debit can reach maxInt(u64) too.
    try L.charge(51, max64);
    try L.charge(51, max64);
    const s2 = try L.status(51, .free);
    try std.testing.expectEqual(@as(u64, max64), s2.used);
    try std.testing.expectEqual(@as(i64, 0), s2.balance); // both sides clamp to the same ceiling
    try std.testing.expect(!(try L.hasBalance(51, .free)));
}
