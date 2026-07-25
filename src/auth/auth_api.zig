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
    const sd = app.cfg.defaults(res.arena);
    var u: ?http.User = if (sessionToken(req)) |tok| app.auth.whoami(tok) else null;
    if (u == null) if (app.keys) |ks| if (http.apiKeyFromReq(req)) |k| if (ks.verify(k)) |uid| {
        u = app.auth.userById(uid);
    };
    const user = u orelse return res.json(.{ .authed = false, .open_registration = app.open_registration, .default_model = sd.model, .default_base_url = sd.base_url }, .{});
    const admin = app.auth.isAdmin(user);
    const e = ent.entitlements(user.plan, admin);
    const ns: neurons.Status = if (app.ledger) |l| l.status(user.id, user.plan) else .{ .granted = 0, .used = 0, .balance = 0, .period_start = 0 };
    try res.json(.{ .authed = true, .email = user.email, .plan = @tagName(user.plan), .id = user.id, .admin = admin, .open_registration = app.open_registration, .workers_ai_available = (app.cf_account_id.len > 0 and app.workers_ai_token.len > 0), .entitlements = .{ .max_swarms = e.max_swarms, .max_minds = e.max_minds, .per_swarm_minds = e.per_swarm_minds, .workers_ai = e.workers_ai, .cloudflare_deploy = e.cloudflare_deploy, .encrypted = e.encrypted }, .neurons = .{ .metered = http.metered(app, user), .granted = ns.granted, .used = ns.used, .balance = ns.balance }, .default_model = sd.model, .default_base_url = sd.base_url }, .{});
}

fn keyNameFromBody(req: *httpz.Request) []const u8 {
    const b = req.body() orelse return "API key";
    const at = std.mem.indexOf(u8, b, "\"name\"") orelse return "API key";
    var i = at + 6;
    while (i < b.len and b[i] != ':') : (i += 1) {}
    while (i < b.len and (b[i] == ':' or b[i] == ' ' or b[i] == '"')) : (i += 1) {}
    var j = i;
    while (j < b.len and b[j] != '"') : (j += 1) {}
    // `j < b.len` means a CLOSING quote was actually found. Without it an empty name ({"name":""})
    // skipped both quotes and ran to the end of the body, handing back "}" as the key's name —
    // and any unterminated name did the same with the rest of the request.
    return if (j < b.len and j > i and j - i <= 60) b[i..j] else "API key";
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

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md (Handlers). This is the front door: who may create an account,
// how fast someone may guess a password, and what an anonymous caller is told.
// ---------------------------------------------------------------------------

test "a private instance stays private: registration is refused and no account appears" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-closed-tmp");
    defer ta.deinit();

    try std.testing.expect(!ta.app.open_registration); // the default this whole test rests on
    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.json(.{ .email = "stranger@example.test", .password = "correct horse battery" });
    try register(&ta.app, web.req, web.res);
    try web.expectStatus(403);
    // Refused, not merely unreported: nobody can log in as that address afterwards.
    try std.testing.expectError(error.BadCredentials, ta.auth.login("stranger@example.test", "correct horse battery"));
}

test "the login throttle answers 429 before it ever looks at the credentials" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-throttle-tmp");
    defer ta.deinit();

    // Wrong password, over and over, from one address — the shape of a guessing run.
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.json(.{ .email = "someone@example.test", .password = "wrong-guess" });
        try login(&ta.app, web.req, web.res);
        try web.expectStatus(401); // each attempt is refused on its merits…
    }
    // …and then the address itself is refused, which is the property that bounds the guess rate.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.json(.{ .email = "someone@example.test", .password = "wrong-guess" });
        try login(&ta.app, web.req, web.res);
        try web.expectStatus(429);
    }
    // The lockout is not a password check: a caller sending NO body at all still gets 429, proving
    // the guard runs before parsing, so a locked-out address cannot even reach auth_core.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try login(&ta.app, web.req, web.res);
        try web.expectStatus(429);
    }
}

test "me tells an anonymous caller nothing beyond the public shape" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-me-tmp");
    defer ta.deinit();

    var web = httpz.testing.init(.{});
    defer web.deinit();
    try me(&ta.app, web.req, web.res);
    const body = (try web.getJson()).object;
    try std.testing.expect(!body.get("authed").?.bool);
    // No identity, no plan, no entitlements for a caller who has not identified themselves.
    try std.testing.expect(body.get("email") == null);
    try std.testing.expect(body.get("plan") == null);
    try std.testing.expect(body.get("entitlements") == null);
    try std.testing.expect(body.get("admin") == null);
}

test "the API-key routes are gated, and a bogus session is not a session" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-keys-tmp");
    defer ta.deinit();

    // Anonymous, and with a cookie that names no session — both are 401, and neither reaches the
    // "api keys unavailable" branch below the gate (app.keys is null here, so a bypass would 500).
    for ([_]?[]const u8{ null, http.COOKIE ++ "=nope" }) |cookie| {
        {
            var web = httpz.testing.init(.{});
            defer web.deinit();
            if (cookie) |c| web.header("cookie", c);
            try keyCreate(&ta.app, web.req, web.res);
            try web.expectStatus(401);
        }
        {
            var web = httpz.testing.init(.{});
            defer web.deinit();
            if (cookie) |c| web.header("cookie", c);
            try keyList(&ta.app, web.req, web.res);
            try web.expectStatus(401);
        }
        {
            var web = httpz.testing.init(.{});
            defer web.deinit();
            if (cookie) |c| web.header("cookie", c);
            web.param("id", "deadbeef");
            try keyRevoke(&ta.app, web.req, web.res);
            try web.expectStatus(401);
        }
    }
}

test "keyNameFromBody takes a name without trusting it, and falls back rather than failing" {
    // It hand-scans the raw body instead of parsing, so the cases that matter are the malformed
    // ones — and the name it returns is interpolated into JSON downstream by api_keys.create,
    // which sanitises it there (see its own tests).
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-name-tmp");
    defer ta.deinit();

    const cases = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body = "{\"name\":\"laptop\"}", .want = "laptop" },
        .{ .body = "{\"name\": \"with spaces\"}", .want = "with spaces" },
        .{ .body = "{}", .want = "API key" }, // absent
        .{ .body = "not json", .want = "API key" }, // unparseable
        .{ .body = "{\"name\":\"\"}", .want = "API key" }, // empty name is not a name
        .{ .body = "{\"name\":\"" ++ "x" ** 61 ++ "\"}", .want = "API key" }, // past the 60-char cap
    };
    for (cases) |c| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.body(c.body);
        try std.testing.expectEqualStrings(c.want, keyNameFromBody(web.req));
    }
}
