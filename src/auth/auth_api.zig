//! Auth HTTP handlers — register / login / logout / me, plus API-key create/list/revoke — thin shims over auth_core.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const ent = @import("../plan/entitlements.zig");
const neurons = @import("../plan/neurons.zig");
const App = http.App;
const COOKIE = http.COOKIE;
const sessionToken = http.sessionToken;
const badReq = http.badReq;
const authErr = http.authErr;

const Creds = struct { email: []const u8, password: []const u8 };

pub fn register(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.open_registration) {
        res.status = 403;
        return res.json(.{ .ok = false, .err = "registration is closed — neuron-loops is in private beta" }, .{});
    }
    const body = (try req.json(Creds)) orelse return badReq(res, "missing email/password");
    app.auth.register(body.email, body.password) catch |e| return authErr(res, e);
    res.status = 201;
    try res.json(.{ .ok = true }, .{});
}

pub fn login(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.login_guard.allowed(req.address)) {
        res.status = 429;
        return res.json(.{ .ok = false, .err = "too many failed attempts — try again later" }, .{});
    }
    const body = (try req.json(Creds)) orelse return badReq(res, "missing email/password");
    const token = app.auth.login(body.email, body.password) catch |e| {
        app.login_guard.fail(req.address);
        return authErr(res, e);
    };
    app.login_guard.success(req.address);
    defer app.gpa.free(token);
    const cookie = try std.fmt.allocPrint(res.arena, "{s}={s}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000", .{ COOKIE, token });
    res.header("Set-Cookie", cookie);
    try res.json(.{ .ok = true }, .{});
}

pub fn logout(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (sessionToken(req)) |tok| app.auth.logout(tok);
    res.header("Set-Cookie", COOKIE ++ "=; HttpOnly; Path=/; Max-Age=0");
    try res.json(.{ .ok = true }, .{});
}

pub fn me(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    var u: ?http.User = if (sessionToken(req)) |tok| app.auth.whoami(tok) else null;
    if (u == null) if (app.keys) |ks| if (http.apiKeyFromReq(req)) |k| if (ks.verify(k)) |uid| {
        u = app.auth.userById(uid);
    };
    const user = u orelse return res.json(.{ .authed = false, .open_registration = app.open_registration, .default_model = app.default_model, .default_base_url = app.default_base_url }, .{});
    const admin = app.auth.isAdmin(user);
    const e = ent.entitlements(user.plan, admin);
    const ns: neurons.Status = if (app.ledger) |l| l.status(user.id, user.plan) else .{ .granted = 0, .used = 0, .balance = 0, .period_start = 0 };
    try res.json(.{ .authed = true, .email = user.email, .plan = @tagName(user.plan), .id = user.id, .admin = admin, .open_registration = app.open_registration, .workers_ai_available = (app.cf_account_id.len > 0 and app.workers_ai_token.len > 0), .entitlements = .{ .max_swarms = e.max_swarms, .max_minds = e.max_minds, .per_swarm_minds = e.per_swarm_minds, .workers_ai = e.workers_ai, .cloudflare_deploy = e.cloudflare_deploy, .encrypted = e.encrypted }, .neurons = .{ .metered = http.metered(app, user), .granted = ns.granted, .used = ns.used, .balance = ns.balance }, .default_model = app.default_model, .default_base_url = app.default_base_url }, .{});
}

fn keyNameFromBody(req: *httpz.Request) []const u8 {
    const b = req.body() orelse return "API key";
    const at = std.mem.indexOf(u8, b, "\"name\"") orelse return "API key";
    var i = at + 6;
    while (i < b.len and b[i] != ':') : (i += 1) {}
    while (i < b.len and (b[i] == ':' or b[i] == ' ' or b[i] == '"')) : (i += 1) {}
    var j = i;
    while (j < b.len and b[j] != '"') : (j += 1) {}
    return if (j > i and j - i <= 60) b[i..j] else "API key";
}

pub fn keyCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireUser(app, req, res) orelse return;
    const ks = app.keys orelse return http.serverErr(res, "api keys unavailable");
    const raw = ks.create(u.id, keyNameFromBody(req)) catch return http.serverErr(res, "could not create key");
    defer app.gpa.free(raw);
    res.status = 201;
    try res.json(.{ .ok = true, .key = raw, .note = "Save this key now — it is shown only once and cannot be retrieved later." }, .{});
}

pub fn keyList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireUser(app, req, res) orelse return;
    const ks = app.keys orelse return http.serverErr(res, "api keys unavailable");
    const views = ks.list(res.arena, u.id) catch return http.serverErr(res, "could not list keys");
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    try arr.appendSlice(res.arena, "{\"keys\":[");
    for (views, 0..) |v, i| {
        if (i > 0) try arr.append(res.arena, ',');
        const item = try std.fmt.allocPrint(res.arena, "{{\"id\":\"{s}\",\"prefix\":\"{s}\",\"name\":\"{s}\",\"created\":{d}}}", .{ v.id, v.prefix, v.name, v.created });
        try arr.appendSlice(res.arena, item);
    }
    try arr.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = arr.items;
}

pub fn keyRevoke(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = http.requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const ks = app.keys orelse return http.serverErr(res, "api keys unavailable");
    const ok = ks.revoke(u.id, id);
    try res.json(.{ .ok = ok, .revoked = ok }, .{});
}
