//! Plans + entitlements — the server-side enforcement wall. `entitlements(plan, is_admin)` maps a user to

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
    if (is_admin) return .{ .max_swarms = 10, .max_minds = 50, .per_swarm_minds = 10, .workers_ai = true, .cloudflare_deploy = true, .encrypted = true };
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
