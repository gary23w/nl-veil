//! sentry_api.zig — the sentry's two surfaces that need the App: its admin routes and its background thread.
//! The sentry itself (inventory, diff, policy, host firewall) is worker/sentry.zig and std-only.
//!
//!   GET    /api/v1/sentry             -> status (sentry.Sentry.statusJson) + the open findings, newest last
//!   POST   /api/v1/sentry/scan        -> inventory now; the status after it
//!   GET    /api/v1/sentry/findings    -> ?since=SEQ&min=low&limit=100&all=1  {ok, findings:[...]}
//!   GET    /api/v1/sentry/inventory   -> the last inventory: listeners, connections, persistence
//!   GET    /api/v1/sentry/rules       -> {ok, rules:[...]}
//!   POST   /api/v1/sentry/rules       -> add; 201 {ok, id}   (sentry.RuleSpec as the body)
//!   DELETE /api/v1/sentry/rules/:id   -> {ok}; 404 when absent
//!   POST   /api/v1/sentry/set         -> {enabled?, posture?, auto_block?, every_s?, allow_port?, disallow_port?, baseline?, ack?}
//!
//! Every route is admin-gated: the sentry reads this machine and, in the enforce posture, changes its firewall.
//! A server built without a sentry (http.testApp, a worker) answers 503 after the gate, never a crash.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const sentry = @import("sentry.zig");
const bu = @import("browser/util.zig"); // sleepMs: the loop is a raw std.Thread, so a raw sleep

const App = http.App;
const log = std.log.scoped(.sentry);

/// First scan a little after boot (the listener, the engine endpoint and the tunnel are then in the inventory),
/// then every `every_s`. Disabled, it wakes every two seconds to see whether it was turned on.
pub fn bgLoop(app: *App) void {
    const s = app.sentry orelse return;
    var warm: u64 = 0;
    while (warm < 15_000) : (warm += 250) bu.sleepMs(250);
    log.info("sentry thread up: {s}", .{if (s.enabled()) "watching this machine" else "idle until enabled (NL_SENTRY=1, veil sentry on, or sentry_set)"});
    while (true) {
        if (s.enabled()) {
            const rep = s.scan(false);
            if (rep.new_findings > 0) log.info("scan: {d} listeners ({d} on network addresses), {d} connections, {d} startup entries, firewall {s}, {d} new finding(s)", .{ rep.listeners, rep.exposed, rep.conns, rep.persist, @tagName(rep.fw), rep.new_findings });
        }
        const every: u64 = if (s.enabled()) s.everySecs() else 2;
        var waited: u64 = 0;
        while (waited < every * 1000) : (waited += 500) bu.sleepMs(500);
    }
}

fn sentryOf(app: *App, res: *httpz.Response) ?*sentry.Sentry {
    return app.sentry orelse {
        res.status = 503;
        res.json(.{ .ok = false, .err = "the sentry is not available on this server" }, .{}) catch {};
        return null;
    };
}

fn reply(app: *App, res: *httpz.Response, body: []const u8) !void {
    _ = app;
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, body);
}

/// GET /api/v1/sentry
pub fn status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    try statusWithFindings(app, res, s);
}

fn statusWithFindings(app: *App, res: *httpz.Response, s: *sentry.Sentry) !void {
    const st = s.statusJson(app.gpa);
    defer app.gpa.free(st);
    const fj = s.findingsJson(app.gpa, s.ackedSeq(), .info, 40);
    defer app.gpa.free(fj);
    // splice the findings into the status object: "...}" -> "...,\"findings\":[...]}"
    const body = try std.fmt.allocPrint(app.gpa, "{s},\"findings\":{s}}}", .{ st[0 .. st.len - 1], fj });
    defer app.gpa.free(body);
    try reply(app, res, body);
}

/// POST /api/v1/sentry/scan
pub fn scanNow(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    _ = s.scan(true);
    try statusWithFindings(app, res, s);
}

/// GET /api/v1/sentry/findings?since=&min=&limit=&all=1
pub fn findings(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    const q = try req.query();
    var since: u64 = if (q.get("since")) |v| (std.fmt.parseInt(u64, v, 10) catch 0) else 0;
    const min = if (q.get("min")) |v| (std.meta.stringToEnum(sentry.Severity, v) orelse .info) else .info;
    const limit: usize = if (q.get("limit")) |v| (std.fmt.parseInt(usize, v, 10) catch 100) else 100;
    const all = if (q.get("all")) |v| std.mem.eql(u8, v, "1") else false;
    if (!all) since = @max(since, s.ackedSeq());
    const fj = s.findingsJson(app.gpa, since, min, @min(limit, sentry.FIND_MAX));
    defer app.gpa.free(fj);
    const body = try std.fmt.allocPrint(app.gpa, "{{\"ok\":true,\"acked\":{d},\"findings\":{s}}}", .{ s.ackedSeq(), fj });
    defer app.gpa.free(body);
    try reply(app, res, body);
}

/// GET /api/v1/sentry/inventory
pub fn inventory(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    const inv = s.inventoryJson(app.gpa);
    defer app.gpa.free(inv);
    try reply(app, res, inv);
}

/// GET /api/v1/sentry/rules
pub fn rules(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    const rj = s.rulesJson(app.gpa);
    defer app.gpa.free(rj);
    const body = try std.fmt.allocPrint(app.gpa, "{{\"ok\":true,\"posture\":\"{s}\",\"rules\":{s}}}", .{ @tagName(s.posture()), rj });
    defer app.gpa.free(body);
    try reply(app, res, body);
}

/// POST /api/v1/sentry/rules
pub fn addRule(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    const raw = req.body() orelse return http.badReq(res, "bad body");
    const p = std.json.parseFromSlice(sentry.RuleSpec, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return http.badReq(res, "bad body: {action, direction, protocol, port, remote?, program?, note?, id?}");
    defer p.deinit();
    switch (s.addRule(p.value)) {
        .id => |id| {
            app.audit.record(u.email, "sentry_rule_add", id);
            res.status = 201;
            try res.json(.{ .ok = true, .id = id, .posture = @tagName(s.posture()), .last_error = s.lastError() }, .{});
        },
        .err => |e| try http.badReq(res, e),
    }
}

/// DELETE /api/v1/sentry/rules/:id
pub fn deleteRule(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    const id = req.param("id") orelse return http.badReq(res, "no id");
    if (!s.removeRule(id)) return http.notFound(res);
    app.audit.record(u.email, "sentry_rule_remove", id);
    try res.json(.{ .ok = true }, .{});
}

/// POST /api/v1/sentry/set
pub fn setRoute(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireAdmin(app, req, res) orelse return;
    const s = sentryOf(app, res) orelse return;
    const raw = req.body() orelse return http.badReq(res, "bad body");
    const p = std.json.parseFromSlice(sentry.Sentry.SetSpec, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return http.badReq(res, "bad body: {enabled?, posture?, auto_block?, every_s?, allow_port?, disallow_port?, baseline?, ack?}");
    defer p.deinit();
    if (s.set(p.value)) |e| return http.badReq(res, e);
    if (p.value.posture) |po| app.audit.record(u.email, "sentry_posture", po);
    if (p.value.enabled) |en| app.audit.record(u.email, if (en) "sentry_on" else "sentry_off", "");
    if (p.value.enabled orelse false) _ = s.scan(false);
    try statusWithFindings(app, res, s);
}

// ================================================================================================= tests

test "every sentry route is admin-gated: an anonymous caller gets 401 before the sentry is touched" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-sentryapi-tmp");
    defer ta.deinit();
    const handlers = [_]*const fn (*App, *httpz.Request, *httpz.Response) anyerror!void{ status, scanNow, findings, inventory, rules, addRule, deleteRule, setRoute };
    for (handlers) |h| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.param("id", "x");
        web.json(.{ .op = "add", .port = 4444, .posture = "enforce", .enabled = true });
        try h(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
}

test "an admin on a server without a sentry gets 503, not a crash" {
    // testApp wires no Sentry (app.sentry stays null) — the shape a worker or a stripped server has.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-sentryapi-tmp2");
    defer ta.deinit();
    var web = httpz.testing.init(.{});
    defer web.deinit();
    try std.testing.expect(sentryOf(&ta.app, web.res) == null);
    try web.expectStatus(503);
}
