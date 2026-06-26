//! Billing seam — POST /billing/checkout. Today it's the NoopBilling upgrade nudge (returns the Pro pitch);

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const ent = @import("../plan/entitlements.zig");
const App = http.App;
const requireUser = http.requireUser;

pub fn billingCheckout(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const pro = ent.entitlements(.pro, false);
    try res.json(.{
        .ok = true,
        .status = "coming_soon",
        .plan = @tagName(u.plan),
        .upgrade = .{ .to = "pro", .price_usd = 15, .max_swarms = pro.max_swarms, .max_minds = pro.max_minds, .workers_ai = true, .cloudflare_deploy = true },
        .note = "Pro autoscales your account onto Cloudflare with hosted Workers AI inference (no BYOK). Billing goes live with the Cloudflare deploy.",
    }, .{});
}
