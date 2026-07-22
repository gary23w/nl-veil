//! Admin (god-mode) HTTP handlers — list users, moderate (ban/unban/delete), list/kill swarms, read the audit log.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const ent = @import("../plan/entitlements.zig");
const chat_service = @import("../worker/chat/service.zig");
const server_config = @import("../config/server_config.zig");
const App = http.App;
const requireAdmin = http.requireAdmin;
const badReq = http.badReq;
const notFound = http.notFound;
const serverErr = http.serverErr;

pub fn adminUsers(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireAdmin(app, req, res) orelse return;
    const users = try app.auth.listUsers(app.gpa);
    defer app.gpa.free(users);
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"users\":[");
    for (users, 0..) |us, i| {
        if (i > 0) try arr.append(app.gpa, ',');
        const item = try std.fmt.allocPrint(res.arena, "{{\"id\":{d},\"email\":\"{s}\",\"plan\":\"{s}\",\"created\":{d},\"live_minds\":{d},\"swarms\":{d},\"banned\":{}}}", .{ us.id, us.email, @tagName(us.plan), us.created, app.sup.liveMindsForUser(us.id), app.sup.activeSwarmsForUser(us.id), us.banned });
        try arr.appendSlice(app.gpa, item);
    }
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

/// GET /api/v1/admin/recipes — the immutable registry currently available to chat turns.
pub fn adminRecipes(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireAdmin(app, req, res) orelse return;
    try res.json(.{ .recipes = app.recipes.recipes }, .{});
}

const RecipeGrantReq = struct { granted: bool };

/// POST /api/v1/admin/users/:uid/recipes/:name — grant/revoke one recipe.
///
/// GRANTING requires the name to resolve in the registry, so a grant can never invent a tool out of an
/// arbitrary string. REVOKING must NOT: the registry check used to run for both verbs, so once a recipe
/// file was deleted the only way to remove its grant returned 404 and the grant string stayed on the user
/// record forever. Since resolveGrants re-intersects registry ∩ grants every turn, any LATER file loading
/// under that same name — with entirely different steps — went instantly live for everyone who still held
/// the stale grant. Revoke is always allowed; it can only ever remove access.
pub fn adminSetRecipeGrant(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const uid_s = req.param("uid") orelse return badReq(res, "no uid");
    const uid = std.fmt.parseInt(u64, uid_s, 10) catch return badReq(res, "uid must be a number");
    const name = req.param("name") orelse return badReq(res, "no recipe name");
    const target = app.auth.userById(uid) orelse return notFound(res);
    const body = (try req.json(RecipeGrantReq)) orelse return badReq(res, "bad body");
    if (body.granted) _ = app.recipes.get(name) orelse return notFound(res);
    _ = app.auth.setToolGrant(target.email, name, body.granted);
    // Record WHO the grant was for — the log could not previously answer "who holds this recipe?", which
    // is the first question asked when a recipe turns out to be dangerous.
    const what = std.fmt.allocPrint(res.arena, "{s} -> uid {d} ({s})", .{ name, uid, target.email }) catch name;
    app.audit.record(admin.email, if (body.granted) "grant_recipe" else "revoke_recipe", what);
    try res.json(.{ .ok = true, .uid = uid, .name = name, .granted = body.granted }, .{});
}

const ConfigReq = struct {
    default_model: []const u8 = "",
    default_base_url: []const u8 = "",
    think_model: []const u8 = "",
    think_base_url: []const u8 = "",
    prompt_model: []const u8 = "",
    prompt_base_url: []const u8 = "",
};

const ServerKeyReq = struct { provider: []const u8, key: []const u8, base_url: []const u8 = "" };

/// POST /api/v1/admin/keys — the INSTANCE-WIDE provider key.
///
/// Without this, setting a default model was only half an answer: every user still had to bring their
/// own key before they could send a single message, which is precisely the setup step a default model
/// exists to remove. Stored in the same sealed vault as everyone else's, under the reserved uid 0.
///
/// Say the consequence plainly, because it is a billing decision, not a convenience: once set, every
/// user's turns spend the admin's credit. A user who stores their own key still uses theirs — the
/// shared key is the last resort in resolveRole, never an override.
pub fn adminPutKey(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const body = (try req.json(ServerKeyReq)) orelse return badReq(res, "bad body");
    app.vault.put(chat_service.SERVER_KEY_UID, body.provider, body.key, body.base_url) catch |e| return badReq(res, switch (e) {
        error.BadProvider => "invalid provider (use a-z0-9-_ , <=32 chars)",
        error.BadKey => "invalid key (1..512 chars, no quotes/backslashes/control chars)",
        error.BadBaseUrl => "invalid base_url",
        else => "could not store the key",
    });
    // The key itself is never echoed, logged, or returned — only that one was set, and for whom.
    app.audit.record(admin.email, "set_server_key", body.provider);
    res.status = 201;
    try res.json(.{ .ok = true, .provider = body.provider }, .{});
}

/// GET /api/v1/admin/keys — which shared keys exist. Metadata only: provider, last4, fingerprint.
pub fn adminListKeys(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireAdmin(app, req, res) orelse return;
    const metas = app.vault.list(chat_service.SERVER_KEY_UID, res.arena) catch return serverErr(res, "could not read the vault");
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"ok\":true,\"keys\":[");
    for (metas, 0..) |m, i| {
        if (i > 0) try arr.append(app.gpa, ',');
        const item = try std.fmt.allocPrint(res.arena, "{{\"provider\":\"{s}\",\"last4\":\"{s}\"}}", .{ m.provider, m.last4 });
        try arr.appendSlice(app.gpa, item);
    }
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

/// DELETE /api/v1/admin/keys/:provider — stop paying for everyone.
pub fn adminDelKey(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const provider = req.param("provider") orelse return badReq(res, "no provider");
    app.vault.del(chat_service.SERVER_KEY_UID, provider);
    app.audit.record(admin.email, "clear_server_key", provider);
    try res.json(.{ .ok = true, .provider = provider, .deleted = true }, .{});
}

/// GET /api/v1/admin/config — the settings this server's admin owns.
pub fn adminGetConfig(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireAdmin(app, req, res) orelse return;
    const sd = app.cfg.defaults(res.arena);
    try res.json(configJson(sd), .{});
}

/// The wire shape, named to MATCH ConfigReq. Returning the Defaults struct directly serialized its own
/// field names (`model`, `base_url`), while the client — and the POST body it had just sent — use
/// `default_model` / `default_base_url`. The save worked; the read-back looked for keys that were not
/// there and rendered "no default", so a setting that had persisted correctly appeared to have been
/// discarded. Request and response now use one vocabulary.
fn configJson(sd: server_config.ServerConfig.Defaults) struct {
    ok: bool,
    default_model: []const u8,
    default_base_url: []const u8,
    think_model: []const u8,
    think_base_url: []const u8,
    prompt_model: []const u8,
    prompt_base_url: []const u8,
} {
    return .{
        .ok = true,
        .default_model = sd.model,
        .default_base_url = sd.base_url,
        .think_model = sd.think_model,
        .think_base_url = sd.think_base_url,
        .prompt_model = sd.prompt_model,
        .prompt_base_url = sd.prompt_base_url,
    };
}

/// POST /api/v1/admin/config — set them, live. No restart: the value is swapped under a mutex and
/// every turn after this one reads the new one. Sending an empty model CLEARS the default, which is
/// the only way to go back to "everyone picks their own" and so is deliberately expressible.
pub fn adminSetConfig(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const body = (try req.json(ConfigReq)) orelse return badReq(res, "bad body");
    app.cfg.setAll(body.default_model, body.default_base_url, body.think_model, body.think_base_url, body.prompt_model, body.prompt_base_url) catch |e| return switch (e) {
        error.TooLong => badReq(res, "that model id or base URL is too long"),
        error.BadInput => badReq(res, "model id and base URL must not contain quotes or control characters"),
    };
    app.audit.record(admin.email, "set_default_model", body.default_model);
    const sd = app.cfg.defaults(res.arena);
    try res.json(configJson(sd), .{});
}

const NewUserReq = struct { email: []const u8, password: []const u8 };

/// POST /api/v1/admin/users — mint an account as the admin.
///
/// Registration is closed by default (NL_OPEN_REGISTRATION), which is the right posture for a box on a
/// LAN — but it left no way to onboard anyone at all. This is that way: the admin creates the account
/// and hands the password over out of band. It reuses `register`, so the same validation, the same
/// argon2id hashing, and the same duplicate-email refusal apply; there is no second account-creation
/// path with its own rules to drift out of step.
pub fn adminCreateUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const body = (try req.json(NewUserReq)) orelse return badReq(res, "bad body");
    app.auth.register(body.email, body.password) catch |e| return switch (e) {
        error.EmailTaken => badReq(res, "that email already has an account"),
        error.BadEmail => badReq(res, "that is not a valid email address"),
        error.WeakInput => badReq(res, "password must be 8-200 characters"),
        else => badReq(res, "could not create the account"),
    };
    // Logged because account creation is exactly what an operator needs to reconstruct afterwards:
    // who was let in, by whom, and when.
    app.audit.record(admin.email, "create_user", body.email);
    res.status = 201;
    try res.json(.{ .ok = true, .email = body.email }, .{});
}

/// GET /api/v1/admin/users/:uid/activity — what one account is actually doing.
///
/// METADATA ONLY, deliberately. Swarms, conversation ids with sizes and last-touched times, token
/// spend — never message content, tool arguments, or file bodies. A conversation's event stream carries
/// shell output, fetched pages and file contents; a route returning it would be a keylogger over
/// everything that user's AI touched, and moderation does not require reading someone's mail. If
/// transcript access is ever genuinely needed it should be its own route, with its own audit action and
/// a recorded reason — not a field quietly added to this one.
pub fn adminUserActivity(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const uid_s = req.param("uid") orelse return badReq(res, "no uid");
    const uid = std.fmt.parseInt(u64, uid_s, 10) catch return badReq(res, "uid must be a number");
    const target = app.auth.userById(uid) orelse return notFound(res);

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"ok\":true,\"email\":");
    try http.jstr(app.gpa, &arr, target.email);
    const head = try std.fmt.allocPrint(res.arena, ",\"id\":{d},\"banned\":{},\"plan\":\"{s}\",\"live_minds\":{d},\"swarms\":{d},\"convs\":[", .{ uid, target.banned, @tagName(target.plan), app.sup.liveMindsForUser(uid), app.sup.activeSwarmsForUser(uid) });
    try arr.appendSlice(app.gpa, head);

    const root = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/convs", .{ app.data, uid });
    var n: usize = 0;
    if (std.Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |ent2| {
            if (ent2.kind != .directory or n >= 200) continue;
            const mpath = std.fmt.allocPrint(res.arena, "{s}/{s}/messages.jsonl", .{ root, ent2.name }) catch continue;
            const st = std.Io.Dir.cwd().statFile(app.io, mpath, .{}) catch continue;
            if (n > 0) try arr.append(app.gpa, ',');
            try arr.appendSlice(app.gpa, "{\"id\":");
            try http.jstr(app.gpa, &arr, ent2.name);
            const tail = try std.fmt.allocPrint(res.arena, ",\"bytes\":{d}}}", .{st.size});
            try arr.appendSlice(app.gpa, tail);
            n += 1;
        }
    } else |_| {}

    try arr.appendSlice(app.gpa, "],\"tool_grants\":[");
    for (target.tool_grants, 0..) |grant, i| {
        if (i > 0) try arr.append(app.gpa, ',');
        try http.jstr(app.gpa, &arr, grant);
    }
    try arr.appendSlice(app.gpa, "]}");
    // Reading another account's activity is itself an administrative act, so it is logged as one.
    app.audit.record(admin.email, "read_activity", target.email);
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

const ModReq = struct { email: []const u8, action: []const u8 };
pub fn adminModerate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const body = (try req.json(ModReq)) orelse return badReq(res, "bad body");
    if (std.ascii.eqlIgnoreCase(body.email, admin.email)) return badReq(res, "cannot moderate your own admin account");
    var ok = false;
    if (std.mem.eql(u8, body.action, "ban")) {
        ok = app.auth.setBanned(body.email, true);
    } else if (std.mem.eql(u8, body.action, "unban")) {
        ok = app.auth.setBanned(body.email, false);
    } else if (std.mem.eql(u8, body.action, "delete")) {
        ok = app.auth.deleteUser(body.email);
    } else return badReq(res, "unknown action (ban|unban|delete)");
    if (!ok) return notFound(res);
    app.audit.record(admin.email, body.action, body.email);
    try res.json(.{ .ok = true, .email = body.email, .action = body.action }, .{});
}

pub fn adminSwarms(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireAdmin(app, req, res) orelse return;
    const swarms = try app.sup.listAll();
    defer app.gpa.free(swarms);
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"swarms\":[");
    for (swarms, 0..) |s, i| {
        if (i > 0) try arr.append(app.gpa, ',');
        const item = try std.fmt.allocPrint(res.arena, "{{\"id\":\"{s}\",\"uid\":{d},\"name\":\"{s}\",\"model\":\"{s}\",\"minds\":{d},\"state\":\"{s}\",\"encrypted\":{},\"restarts\":{d},\"breaker\":{}}}", .{ s.id, s.uid, s.name, s.model, s.minds, @tagName(s.state), s.encrypted, s.restarts, s.breaker_open });
        try arr.appendSlice(app.gpa, item);
    }
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

pub fn adminKill(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const admin = requireAdmin(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    if (app.sup.get(id) == null) return notFound(res);
    app.sup.remove(id);
    app.audit.record(admin.email, "kill_swarm", id);
    try res.json(.{ .ok = true, .killed = true }, .{});
}

pub fn adminAudit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireAdmin(app, req, res) orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, app.audit.path, res.arena, .limited(64 << 20)) catch "";
    const integ = if (app.audit.verify()) |n|
        std.fmt.allocPrint(res.arena, "valid:{d}", .{n}) catch "valid"
    else |e|
        @errorName(e);
    res.header("X-Audit-Integrity", integ);
    // .TEXT, not .EVENTS: a one-shot jsonl dump. An empty .EVENTS response is sent without Content-Length
    // (SSE framing), leaving a keep-alive client hanging for the body until the 60s idle reap.
    res.content_type = .TEXT;
    res.body = data;
}
