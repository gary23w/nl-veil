//! Billing seam — POST /billing/checkout returns the Pro upgrade pitch (billing goes live with the Cloudflare deploy).

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
        // Every capability claim is READ FROM the pro row, never restated as a literal. The caps
        // already were; `workers_ai` and `cloudflare_deploy` were hardcoded `true` and merely
        // happened to match. Flip either flag in entitlements.zig and this endpoint would have gone
        // on advertising a capability the plan no longer grants — the same shape as the stale
        // "sealed at rest" strings in H14. `price_usd` stays a literal because no source of truth
        // for it exists yet; billing goes live with the Cloudflare deploy.
        .upgrade = .{ .to = "pro", .price_usd = 15, .max_swarms = pro.max_swarms, .max_minds = pro.max_minds, .workers_ai = pro.workers_ai, .cloudflare_deploy = pro.cloudflare_deploy },
        .note = "Pro autoscales your account onto Cloudflare with hosted Workers AI inference (no BYOK). Billing goes live with the Cloudflare deploy.",
    }, .{});
}

// ---------------------------------------------------------------------------
// tests — a pitch is a user-facing PROMISE, so the thing worth pinning is that what it advertises
// is what the plan actually grants. See harness/TESTING.md.
// ---------------------------------------------------------------------------

test "the pitch is behind the same door as everything else: anonymous gets 401, not a price list" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-billing-anon-tmp");
    defer ta.deinit();

    var web = httpz.testing.init(.{});
    defer web.deinit();
    try billingCheckout(&ta.app, web.req, web.res);
    try web.expectStatus(401);
    // requireUser writes the 401 itself and the handler returns — so nothing below it ran, and no
    // plan name for an unauthenticated caller can appear in the body.
    try std.testing.expect(std.mem.indexOf(u8, web.res.body, "upgrade") == null);
}

test "what the upgrade advertises IS what the pro plan grants — no restated literals" {
    // The seam this guards: caps were read from entitlements(.pro) while the capability flags were
    // hardcoded `true` beside them. Both agreed, but only by coincidence — nothing tied the promise
    // to the grant, so a change to the pro row would have left the endpoint selling the old one.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-billing-auth-tmp");
    defer ta.deinit();

    // Auth fails OPEN, so register/login succeed with no store behind them and the failure would
    // surface later as an unrelated status. Probe the store directly and skip honestly (0053).
    {
        const probe = "bmxfdmVpbF9iaWxsaW5nX3Byb2Jl";
        ta.auth.nb.put("nl_billing_probe", probe) catch return error.SkipZigTest;
        const got = (ta.auth.nb.get("nl_billing_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, probe)) return error.SkipZigTest;
    }
    // The FIRST account to register becomes the admin when no admin email is configured
    // (`isAdminEmail` falls back to `next_id == 1`), and an admin is seeded onto `.pro`. Burn that
    // slot deliberately: the case worth testing is a FREE user being shown an upgrade pitch, and a
    // first-user fixture would have made "current plan" and "advertised tier" the same string —
    // the assertion below would pass while proving nothing.
    ta.auth.register("owner@example.test", "correct horse battery") catch return error.SkipZigTest;
    ta.auth.register("buyer@example.test", "correct horse battery") catch return error.SkipZigTest;
    const token = ta.auth.login("buyer@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(token);
    const cookie = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{token});
    defer gpa.free(cookie);

    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.header("cookie", cookie);
    try billingCheckout(&ta.app, web.req, web.res);
    try web.expectStatus(200);

    const body = (try web.getJson()).object;
    const up = body.get("upgrade").?.object;
    const pro = ent.entitlements(.pro, false);

    try std.testing.expectEqual(@as(i64, @intCast(pro.max_swarms)), up.get("max_swarms").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(pro.max_minds)), up.get("max_minds").?.integer);
    try std.testing.expectEqual(pro.workers_ai, up.get("workers_ai").?.bool);
    try std.testing.expectEqual(pro.cloudflare_deploy, up.get("cloudflare_deploy").?.bool);

    // The pitch must name the tier it is selling, and the caller's CURRENT plan must be their own
    // rather than the one being advertised — a fresh account is free, and reading back "pro" here
    // would mean the endpoint had told a free user they were already upgraded.
    try std.testing.expectEqualStrings("pro", up.get("to").?.string);
    try std.testing.expectEqualStrings("free", body.get("plan").?.string);
}
