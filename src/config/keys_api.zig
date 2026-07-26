//! BYOK key-vault HTTP handlers — POST a provider key (sealed, write-only), GET the metadata list, DELETE by provider.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const serverErr = http.serverErr;

const KeyReq = struct { provider: []const u8, key: []const u8, base_url: []const u8 = "" };

pub fn putKey(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (req.json(KeyReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    app.vault.put(u.id, body.provider, body.key, body.base_url) catch |e| return badReq(res, switch (e) {
        error.BadProvider => "invalid provider (use a-z0-9-_ , <=32 chars)",
        error.BadKey => "invalid key (1..512 chars, valid UTF-8, no quotes/backslashes/control chars)",
        error.BadBaseUrl => "invalid base_url",
        else => "could not store key",
    });
    var dig: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body.key, &dig, .{});
    const fp = std.fmt.bytesToHex(dig[0..8], .lower);
    const last4 = if (body.key.len >= 4) body.key[body.key.len - 4 ..] else body.key;
    res.status = 201;
    try res.json(.{ .ok = true, .provider = body.provider, .last4 = last4, .fingerprint = fp[0..] }, .{});
}

pub fn listKeys(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const metas = app.vault.list(u.id, res.arena) catch return serverErr(res, "could not read vault");
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"keys\":[");
    for (metas, 0..) |m, i| {
        if (i > 0) try arr.append(app.gpa, ',');
        const item = try std.fmt.allocPrint(res.arena, "{{\"provider\":\"{s}\",\"last4\":\"{s}\",\"fingerprint\":\"{s}\",\"base_url\":\"{s}\",\"created\":{d}}}", .{ m.provider, m.last4, m.fingerprint, m.base_url, m.created });
        try arr.appendSlice(app.gpa, item);
    }
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

pub fn delKey(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const provider = req.param("provider") orelse return badReq(res, "no provider");
    app.vault.del(u.id, provider);
    try res.json(.{ .ok = true, .provider = provider, .deleted = true }, .{});
}

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md (Handlers). These are the routes that read and write other
// people's provider secrets, so the property worth pinning first is that NONE of them does any
// work before the caller is identified.
// ---------------------------------------------------------------------------

test "every vault route is gated: an anonymous caller gets 401 and the vault is never touched" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-keysapi-tmp");
    defer ta.deinit();

    // Each handler, unauthenticated, with a body and params good enough that ONLY the auth gate can
    // be what rejects it — so a future edit that moves requireUser below the work shows up here.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.json(.{ .provider = "openai", .key = "sk-live-not-a-real-key", .base_url = "" });
        try putKey(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try listKeys(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.param("provider", "openai");
        try delKey(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }

    // And nothing reached the store: an anonymous POST must not have written a key for anyone.
    // (uid 0 is what a caller-less request would fall to if the gate were ever bypassed.)
    try std.testing.expect(!ta.vault.has(0, "openai"));
}

test "the authenticated round trip: store a key, list it as metadata only, delete it" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-keysapi-auth-tmp");
    defer ta.deinit();

    // The STORE has to work, and register/login cannot tell us that: Auth fails OPEN, so both
    // succeed off its in-memory maps with no neuron binary present (CI has none — bin/ is
    // gitignored) and the failure would surface three steps later as an inexplicable 400 from the
    // vault, which is exactly how this test first went red on CI. Probe it directly and skip
    // honestly instead.
    {
        const probe = "bmxfdmVpbF9rZXlzYXBpX3Byb2Jl";
        ta.vault.nb.put("nl_keysapi_probe", probe) catch return error.SkipZigTest;
        const got = (ta.vault.nb.get("nl_keysapi_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, probe)) return error.SkipZigTest;
    }

    // A real account and a real session, through the same doors the server uses.
    ta.auth.register("someone@example.test", "correct horse battery") catch |e| switch (e) {
        else => return error.SkipZigTest, // no usable store on this box
    };
    const token = ta.auth.login("someone@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(token);
    const cookie = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{token});
    defer gpa.free(cookie);

    const SECRET = "sk-live-obviously-fake-9999";

    // A bad provider is rejected on ITS message, not the key's — the error mapping is the contract
    // the UI shows the user.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        web.json(.{ .provider = "../../etc", .key = SECRET, .base_url = "" });
        try putKey(&ta.app, web.req, web.res);
        try web.expectStatus(400);
    }
    // Stored: 201, and the reply echoes only last4 + fingerprint — never the key.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        web.json(.{ .provider = "openai", .key = SECRET, .base_url = "" });
        try putKey(&ta.app, web.req, web.res);
        try web.expectStatus(201);
        const body = (try web.getJson()).object;
        try std.testing.expectEqualStrings("9999", body.get("last4").?.string);
        try std.testing.expect(body.get("fingerprint").?.string.len == 16);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, SECRET) == null);
    }
    // The list is metadata: the secret must not appear anywhere in the response body.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        try listKeys(&ta.app, web.req, web.res);
        const body = web.res.body;
        try std.testing.expect(std.mem.indexOf(u8, body, "openai") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "9999") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, SECRET) == null);
    }
    // Deleted, and the vault agrees.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        web.param("provider", "openai");
        try delKey(&ta.app, web.req, web.res);
        try web.expectStatus(200);
    }
    try std.testing.expect(!ta.vault.has(1, "openai"));
}
