//! Auth HTTP handlers — register / login / logout / me, plus API-key create/list/revoke — thin shims over auth_core.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const ent = @import("../plan/entitlements.zig");
const neurons = @import("../plan/neurons.zig");
const Neuron = @import("../worker/neuron/client.zig").Neuron;
const App = http.App;
const COOKIE = http.COOKIE;
const sessionToken = http.sessionToken;
const badReq = http.badReq;
const authErr = http.authErr;

const Creds = struct { email: []const u8, password: []const u8 };

pub fn register(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // NEVER through a tunnel or proxy, whatever the flag says. A Cloudflare Tunnel makes this server
    // reachable from the whole internet at a loopback socket; open registration there would hand accounts
    // to anyone who found the URL. The tunnel also refuses to start while registration is open (cf_tunnel);
    // this is the second lock on the same door.
    if (http.viaProxy(req)) {
        res.status = 403;
        return res.json(.{ .ok = false, .err = "registration is not available through a tunnel or proxy" }, .{});
    }
    if (!app.open_registration) {
        res.status = 403;
        return res.json(.{ .ok = false, .err = "registration is closed — neuron-loops is in private beta" }, .{});
    }
    const body = (req.json(Creds) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "missing email/password");
    app.auth.register(body.email, body.password) catch |e| return switch (e) {
        error.StorageFailure => http.serverErr(res, "could not persist account"),
        else => authErr(res, e),
    };
    res.status = 201;
    try res.json(.{ .ok = true }, .{});
}

pub fn login(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.login_guard.allowed(http.clientAddress(req))) {
        res.status = 429;
        return res.json(.{ .ok = false, .err = "too many failed attempts — try again later" }, .{});
    }
    const body = (req.json(Creds) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "missing email/password");
    const token = app.auth.login(body.email, body.password) catch |e| {
        app.login_guard.fail(http.clientAddress(req));
        return authErr(res, e);
    };
    app.login_guard.success(http.clientAddress(req));
    defer app.gpa.free(token);
    // Secure when the visitor came through Cloudflare (the edge speaks HTTPS to them); never on a plain
    // local http origin, where a Secure cookie would simply not be stored and every login would fail.
    const cookie = try std.fmt.allocPrint(res.arena, "{s}={s}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000{s}", .{ COOKIE, token, if (http.viaProxy(req)) "; Secure" else "" });
    res.header("Set-Cookie", cookie);
    try res.json(.{ .ok = true }, .{});
}

pub fn logout(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.header("Set-Cookie", COOKIE ++ "=; HttpOnly; Path=/; Max-Age=0");
    if (sessionToken(req)) |tok| app.auth.logoutChecked(tok) catch return http.serverErr(res, "could not persist logout");
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
    const ns: neurons.Status = if (app.ledger) |l| l.status(user.id, user.plan) catch return http.serverErr(res, "neuron ledger unavailable") else .{ .granted = 0, .used = 0, .balance = 0, .period_start = 0 };
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
    const ok = ks.revoke(u.id, id) catch return http.serverErr(res, "could not persist API key revocation");
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

test "registration reports storage failure without creating a live-only account" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-register-store-tmp");
    defer ta.deinit();
    ta.app.open_registration = true;
    const email = "new@example.test";
    const password = "correct horse battery";
    const bin = ta.auth.nb.bin;
    ta.auth.nb.bin = "__nl_no_such_neuron_bin__";
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.json(.{ .email = email, .password = password });
        try register(&ta.app, web.req, web.res);
        try web.expectStatus(500);
    }
    try std.testing.expect(ta.auth.idForEmail(email) == null);
    try std.testing.expectEqual(@as(u64, 1), ta.auth.next_id);
    try std.testing.expectError(error.BadCredentials, ta.auth.login(email, password));

    ta.auth.nb.bin = bin;
    const probe = "bmxfdXNlcl9yZWdpc3RyYXRpb25fcHJvYmU=";
    ta.auth.nb.put("nl_registration_probe", probe) catch return error.SkipZigTest;
    const got = (ta.auth.nb.get("nl_registration_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, probe)) return error.SkipZigTest;
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.json(.{ .email = email, .password = password });
        try register(&ta.app, web.req, web.res);
        try web.expectStatus(201);
    }
    try std.testing.expectEqual(@as(u64, 1), ta.auth.idForEmail(email).?);
    var reloaded = http.Auth.init(gpa, ta.auth.nb);
    defer reloaded.deinit();
    try reloaded.warm();
    try std.testing.expectEqual(@as(u64, 1), reloaded.idForEmail(email).?);
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

test "logout confirms stored revocation before success and rejects a failed delete" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-logout-tmp");
    defer ta.deinit();

    const probe = "bmxfdmVpbF9sb2dvdXRfcHJvYmU=";
    ta.auth.nb.put("nl_logout_probe", probe) catch return error.SkipZigTest;
    const got = (ta.auth.nb.get("nl_logout_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, probe)) return error.SkipZigTest;

    ta.auth.register("u@example.test", "correct horse battery") catch return error.SkipZigTest;
    const token = try ta.auth.login("u@example.test", "correct horse battery");
    defer gpa.free(token);
    {
        const scope = try std.fmt.allocPrint(gpa, "s_{s}", .{token});
        defer gpa.free(scope);
        const stored = (try ta.auth.nb.get(scope)) orelse return error.SessionNotStored;
        gpa.free(stored);
    }
    const cookie = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{token});
    defer gpa.free(cookie);
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        try logout(&ta.app, web.req, web.res);
        try web.expectStatus(200);
    }
    try std.testing.expect(ta.auth.whoami(token) == null);
    {
        var reloaded = http.Auth.init(gpa, ta.auth.nb);
        defer reloaded.deinit();
        try reloaded.warm();
        try std.testing.expect(reloaded.whoami(token) == null);
    }

    const failed_token = try ta.auth.login("u@example.test", "correct horse battery");
    defer gpa.free(failed_token);
    {
        const scope = try std.fmt.allocPrint(gpa, "s_{s}", .{failed_token});
        defer gpa.free(scope);
        const stored = (try ta.auth.nb.get(scope)) orelse return error.SessionNotStored;
        gpa.free(stored);
    }
    const failed_cookie = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{failed_token});
    defer gpa.free(failed_cookie);
    const bin = ta.auth.nb.bin;
    ta.auth.nb.bin = "__nl_no_such_neuron_bin__";
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", failed_cookie);
        try logout(&ta.app, web.req, web.res);
        try web.expectStatus(500);
    }
    ta.auth.nb.bin = bin;
    try std.testing.expect(ta.auth.whoami(failed_token) == null);
}

test "password change, ban, and account recreation reject stale stored sessions" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-session-generation-tmp");
    defer ta.deinit();

    const probe = "bmxfc2Vzc2lvbl9nZW5lcmF0aW9uX3Byb2Jl";
    ta.auth.nb.put("nl_session_generation_probe", probe) catch return error.SkipZigTest;
    const got = (ta.auth.nb.get("nl_session_generation_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, probe)) return error.SkipZigTest;

    const email = "u@example.test";
    const old_password = "correct horse battery";
    const new_password = "new correct horse battery";
    try ta.auth.register(email, old_password);
    const original_id = ta.auth.idForEmail(email).?;

    const password_token = try ta.auth.login(email, old_password);
    defer gpa.free(password_token);
    const password_scope = try std.fmt.allocPrint(gpa, "s_{s}", .{password_token});
    defer gpa.free(password_scope);
    const password_record = (try ta.auth.nb.get(password_scope)) orelse return error.SessionNotStored;
    defer gpa.free(password_record);
    try std.testing.expect(ta.auth.setPassword(email, new_password));
    try std.testing.expect(ta.auth.whoami(password_token) == null);
    // Simulate an individual cleanup delete failing while the old record remains on disk.
    try ta.auth.nb.put(password_scope, password_record);
    {
        var reloaded = http.Auth.init(gpa, ta.auth.nb);
        defer reloaded.deinit();
        try reloaded.warm();
        try std.testing.expect(reloaded.whoami(password_token) == null);
    }

    const ban_token = try ta.auth.login(email, new_password);
    defer gpa.free(ban_token);
    const ban_scope = try std.fmt.allocPrint(gpa, "s_{s}", .{ban_token});
    defer gpa.free(ban_scope);
    const ban_record = (try ta.auth.nb.get(ban_scope)) orelse return error.SessionNotStored;
    defer gpa.free(ban_record);
    try std.testing.expect(try ta.auth.setBanned(email, true));
    try std.testing.expect(try ta.auth.setBanned(email, false));
    try ta.auth.nb.put(ban_scope, ban_record);
    {
        var reloaded = http.Auth.init(gpa, ta.auth.nb);
        defer reloaded.deinit();
        try reloaded.warm();
        try std.testing.expect(reloaded.whoami(ban_token) == null);
    }

    const deleted_token = try ta.auth.login(email, new_password);
    defer gpa.free(deleted_token);
    const deleted_scope = try std.fmt.allocPrint(gpa, "s_{s}", .{deleted_token});
    defer gpa.free(deleted_scope);
    const deleted_record = (try ta.auth.nb.get(deleted_scope)) orelse return error.SessionNotStored;
    defer gpa.free(deleted_record);
    try std.testing.expect(try ta.auth.deleteUser(email));
    {
        var recreated = http.Auth.init(gpa, ta.auth.nb);
        defer recreated.deinit();
        try recreated.warm();
        try recreated.register(email, old_password);
        // A new account must not inherit the deleted account's user-data namespace.
        try std.testing.expect(recreated.idForEmail(email).? != original_id);
        try ta.auth.nb.put(deleted_scope, deleted_record);
        const valid_token = try recreated.login(email, old_password);
        defer gpa.free(valid_token);
        var reloaded = http.Auth.init(gpa, ta.auth.nb);
        defer reloaded.deinit();
        try reloaded.warm();
        try std.testing.expect(reloaded.whoami(deleted_token) == null);
        try std.testing.expect(reloaded.whoami(valid_token) != null);
    }
}

test "a deleted user's persisted API key cannot become a replacement user's key" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-uid-reuse-tmp");
    defer ta.deinit();

    ta.auth.register("admin@example.test", "correct horse battery") catch return error.SkipZigTest;
    try ta.auth.register("departed@example.test", "correct horse battery");
    const old_id = ta.auth.idForEmail("departed@example.test").?;
    var keys = http.ApiKeys.init(gpa, ta.auth.nb);
    defer keys.deinit();
    const old_key = try keys.create(old_id, "old account");
    defer gpa.free(old_key);
    try std.testing.expect(keys.persisted(old_key));
    try std.testing.expect(try ta.auth.deleteUser("departed@example.test"));

    var restarted = http.Auth.init(gpa, ta.auth.nb);
    defer restarted.deinit();
    try restarted.warm();
    try restarted.register("replacement@example.test", "correct horse battery");

    var restored_keys = http.ApiKeys.init(gpa, ta.auth.nb);
    defer restored_keys.deinit();
    try restored_keys.warm();
    try std.testing.expectEqual(old_id, restored_keys.verify(old_key).?);
    try std.testing.expect(restarted.userById(old_id) == null);
    try std.testing.expect(restarted.idForEmail("replacement@example.test").? != old_id);
}

test "failed privilege readback restores the stored denial before restart" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-privilege-readback-tmp");
    defer ta.deinit();
    const email = "victim@example.test";
    ta.auth.register("operator@example.test", "correct horse battery") catch return error.SkipZigTest;
    ta.auth.register(email, "correct horse battery") catch return error.SkipZigTest;
    const uid = ta.auth.idForEmail(email).?;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(email, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..6], .lower);
    var scope_buf: [16]u8 = undefined;
    const scope = try std.fmt.bufPrint(&scope_buf, "u_{s}", .{hex});
    var fault: Neuron.TestFault = .{};
    ta.auth.nb.test_fault = &fault;

    fault.fail_get_after_put_scope = scope;
    try std.testing.expectError(error.TestInjectedReadFailure, ta.auth.setToolGrant(email, "research_brief", true));
    try std.testing.expect(!http.Auth.hasToolGrant(ta.auth.userById(uid).?, "research_brief"));
    {
        var reloaded = http.Auth.init(gpa, ta.auth.nb);
        defer reloaded.deinit();
        try reloaded.warm();
        try std.testing.expect(!http.Auth.hasToolGrant(reloaded.userById(uid).?, "research_brief"));
    }

    fault.fail_get_after_put_scope = scope;
    try std.testing.expectError(error.TestInjectedReadFailure, ta.auth.setPlan(email, .pro));
    try std.testing.expect(ta.auth.userById(uid).?.plan == .free);
    {
        var reloaded = http.Auth.init(gpa, ta.auth.nb);
        defer reloaded.deinit();
        try reloaded.warm();
        try std.testing.expect(reloaded.userById(uid).?.plan == .free);
    }

    try std.testing.expect(try ta.auth.setBanned(email, true));
    fault.fail_get_after_put_scope = scope;
    try std.testing.expectError(error.TestInjectedReadFailure, ta.auth.setBanned(email, false));
    try std.testing.expect(ta.auth.userById(uid).?.banned);
    var reloaded = http.Auth.init(gpa, ta.auth.nb);
    defer reloaded.deinit();
    try reloaded.warm();
    try std.testing.expect(reloaded.userById(uid).?.banned);
}

test "legacy deleted accounts and interrupted registrations leave no reusable ID" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-authapi-legacy-uid-tmp");
    defer ta.deinit();

    // Simulate a pre-reservation release: its user row was forgotten, while an old
    // key still carries UID 2. A newly registered account must stay out of that namespace.
    var keys = http.ApiKeys.init(gpa, ta.auth.nb);
    defer keys.deinit();
    const old_key = try keys.create(2, "legacy account");
    defer gpa.free(old_key);
    if (!keys.persisted(old_key)) return error.SkipZigTest;
    try ta.auth.nb.put("u_legacy_deleted", "old-record");
    try ta.auth.nb.delChecked("u_legacy_deleted");
    var upgraded = http.Auth.init(gpa, ta.auth.nb);
    defer upgraded.deinit();
    try upgraded.warm();
    try upgraded.register("new@example.test", "correct horse battery");
    const first_id = upgraded.idForEmail("new@example.test").?;
    try std.testing.expect(first_id >= (@as(u64, 1) << 40));
    try std.testing.expect(upgraded.userById(2) == null);

    // A reserved ID with no user is a safe gap after an interrupted registration.
    const gap_id = first_id + 1;
    const gap_scope = try std.fmt.allocPrint(gpa, "auth_uid_reserved_{d}", .{gap_id});
    defer gpa.free(gap_scope);
    try ta.auth.nb.put(gap_scope, "reserved-v1");
    var restarted = http.Auth.init(gpa, ta.auth.nb);
    defer restarted.deinit();
    try restarted.warm();
    try restarted.register("later@example.test", "correct horse battery");
    try std.testing.expectEqual(gap_id + 1, restarted.idForEmail("later@example.test").?);
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
