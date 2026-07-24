//! Plans + entitlements — the server-side enforcement wall; `entitlements(plan, is_admin)` maps a user to their caps.

pub const Plan = enum { free, pro, max };

pub const Entitlements = struct {
    max_swarms: usize,
    max_minds: usize,
    per_swarm_minds: usize,
    workers_ai: bool,
    cloudflare_deploy: bool,
    encrypted: bool,
};

pub fn entitlements(plan: Plan, is_admin: bool) Entitlements {
    // admin (self-host / localhost operator): a big per-swarm ceiling so a chat-cast can line up to 30 minds
    if (is_admin) return .{ .max_swarms = 10, .max_minds = 60, .per_swarm_minds = 30, .workers_ai = true, .cloudflare_deploy = true, .encrypted = true };
    return switch (plan) {
        .free => .{ .max_swarms = 1, .max_minds = 3, .per_swarm_minds = 5, .workers_ai = true, .cloudflare_deploy = false, .encrypted = false },
        .pro => .{ .max_swarms = 3, .max_minds = 5, .per_swarm_minds = 5, .workers_ai = true, .cloudflare_deploy = true, .encrypted = false },
        .max => .{ .max_swarms = 6, .max_minds = 12, .per_swarm_minds = 8, .workers_ai = true, .cloudflare_deploy = true, .encrypted = false },
    };
}

pub fn monthlyNeuronGrant(plan: Plan) u64 {
    return switch (plan) {
        .free => 500_000,
        .pro => 1_500_000,
        .max => 6_000_000,
    };
}

// entitlements() IS the paywall: swarm creation, mind counts, hosted deploy and encryption all gate on the row
// it returns (worker/deploy/service.zig, auth/auth_api.zig), and plan/billing_seam.zig quotes the Pro row back
// to the user as the upgrade pitch. A silent widening here gives a paid feature away; a silent narrowing locks
// a paying customer out of something they bought. So the rows are pinned literally, not re-derived.

const std = @import("std");

test "entitlements: each plan buys exactly the caps this file states" {
    // Three plans today, and BOTH switches in this file are exhaustive (no `else` arm) — a fourth variant is a
    // compile error rather than a silent default, and this line is the reminder to give it a row here too.
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(Plan).@"enum".fields.len);

    try std.testing.expectEqual(Entitlements{ .max_swarms = 1, .max_minds = 3, .per_swarm_minds = 5, .workers_ai = true, .cloudflare_deploy = false, .encrypted = false }, entitlements(.free, false));
    try std.testing.expectEqual(Entitlements{ .max_swarms = 3, .max_minds = 5, .per_swarm_minds = 5, .workers_ai = true, .cloudflare_deploy = true, .encrypted = false }, entitlements(.pro, false));
    try std.testing.expectEqual(Entitlements{ .max_swarms = 6, .max_minds = 12, .per_swarm_minds = 8, .workers_ai = true, .cloudflare_deploy = true, .encrypted = false }, entitlements(.max, false));

    // Two rows that are easy to widen by accident. Pro buys hosted deploy and more swarms but NOT a bigger
    // cast — its per-swarm ceiling is the same 5 as free. And `encrypted` is off for every paying tier.
    try std.testing.expectEqual(entitlements(.free, false).per_swarm_minds, entitlements(.pro, false).per_swarm_minds);
    for ([_]Plan{ .free, .pro, .max }) |p| try std.testing.expect(!entitlements(p, false).encrypted);
}

test "entitlements: the admin flag replaces the plan row wholesale and is the only row that gets encryption" {
    const admin_row = Entitlements{ .max_swarms = 10, .max_minds = 60, .per_swarm_minds = 30, .workers_ai = true, .cloudflare_deploy = true, .encrypted = true };
    // The flag short-circuits BEFORE the switch, so the operator's stored plan is irrelevant: a self-hosted
    // admin left sitting on `free` still gets the 30-mind chat-cast ceiling the doc comment promises.
    for ([_]Plan{ .free, .pro, .max }) |p| try std.testing.expectEqual(admin_row, entitlements(p, true));

    // …and admin is never a downgrade: it dominates the top paid tier on every numeric cap, and it is the
    // only way to reach `encrypted` at all.
    const top = entitlements(.max, false);
    try std.testing.expect(admin_row.max_swarms > top.max_swarms);
    try std.testing.expect(admin_row.max_minds > top.max_minds);
    try std.testing.expect(admin_row.per_swarm_minds > top.per_swarm_minds);
    try std.testing.expect(admin_row.encrypted and !top.encrypted);
}

test "entitlements: caps only widen as the plan goes up, and no tier is cut off from Workers AI" {
    const f = entitlements(.free, false);
    const p = entitlements(.pro, false);
    const m = entitlements(.max, false);
    try std.testing.expect(f.max_swarms < p.max_swarms and p.max_swarms < m.max_swarms);
    try std.testing.expect(f.max_minds < p.max_minds and p.max_minds < m.max_minds);
    try std.testing.expect(f.per_swarm_minds <= p.per_swarm_minds and p.per_swarm_minds <= m.per_swarm_minds);
    // workers_ai is true on every tier: this flag is NOT what keeps a free user off hosted inference. What
    // meters them is the neuron ledger (plan/neurons.zig), so nothing downstream may start treating this as
    // the gate — a free account that reads `workers_ai = false` here would lose inference it is entitled to.
    try std.testing.expect(f.workers_ai and p.workers_ai and m.workers_ai);
    // Hosted Cloudflare deploy is the one flag a paid plan actually turns on.
    try std.testing.expect(!f.cloudflare_deploy and p.cloudflare_deploy and m.cloudflare_deploy);
}

test "monthlyNeuronGrant: a strictly increasing per-plan constant that the admin flag deliberately does not touch" {
    try std.testing.expectEqual(@as(u64, 500_000), monthlyNeuronGrant(.free));
    try std.testing.expectEqual(@as(u64, 1_500_000), monthlyNeuronGrant(.pro));
    try std.testing.expectEqual(@as(u64, 6_000_000), monthlyNeuronGrant(.max));
    try std.testing.expect(monthlyNeuronGrant(.free) < monthlyNeuronGrant(.pro));
    try std.testing.expect(monthlyNeuronGrant(.pro) < monthlyNeuronGrant(.max));

    // Deliberate asymmetry with entitlements(): there is no is_admin parameter here. The admin flag lifts the
    // STRUCTURAL caps but not the metered-AI budget — main.zig calls status(u.id, u.plan) with no override, so
    // a self-hosted operator sitting on `free` still runs on 500k neurons a period. If that ever needs to
    // change it has to change HERE, not by teaching the ledger about admins.
    try std.testing.expect(entitlements(.free, true).max_swarms > entitlements(.free, false).max_swarms);
}
