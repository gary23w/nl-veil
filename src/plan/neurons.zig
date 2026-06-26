//! Neuron ledger — the metered-AI budget that makes multi-tenant Workers AI safe to deploy. 1 user-neuron = 1

const std = @import("std");
const Neuron = @import("../orchestrate/neuron_client.zig").Neuron;
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
        const granted = ent.monthlyNeuronGrant(plan) + r.topup;
        const bal = @as(i64, @intCast(granted)) - @as(i64, @intCast(r.used));
        return .{ .granted = granted, .used = r.used, .balance = bal, .period_start = r.period_start };
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
