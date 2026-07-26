//! The five routes the browser extension speaks, plus one status route for the desk/web UI.
//!
//!   GET  /api/v1/browser/ext/hello   — unauthenticated identity probe; how the extension FINDS the server.
//!   POST /api/v1/browser/ext/pair    — loopback-only; mints/returns the relay token.
//!   GET  /api/v1/browser/ext/poll    — long-poll for the next CDP command batch (token).
//!   POST /api/v1/browser/ext/result  — deliver one command's reply (token).
//!   POST /api/v1/browser/ext/bye     — the extension is going away (token).
//!   GET  /api/v1/browser/ext/status  — authenticated; is a browser connected, and which one.
//!
//! AUTH MODEL, and why it is not the app's normal one. The extension is not a user — it is the user's own
//! browser offering itself as a peripheral, and it has no session cookie and no API key. So these routes carry
//! their own bearer: a per-process token handed out ONLY to a caller on loopback (`pair`). That is the real
//! boundary. A remote attacker cannot pair, because the request has to originate on the machine; a page in the
//! user's browser cannot pair either, because it cannot read the response of a cross-origin POST it isn't
//! allowed to make — and even if pairing leaked, the relay's blast radius is one tab the extension itself
//! opened. The token is compared in full and never logged.
//!
//! CORS is deliberately absent: an MV3 service worker fetch is not a page fetch and is exempt from CORS given
//! host permissions, so adding Access-Control-Allow-Origin here would only open the relay to web pages.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../../gateway/http.zig");
const ext = @import("ext.zig");

const App = http.App;
const requireUser = http.requireUser;

/// Bumped when the wire contract between server and extension changes shape. The extension sends its own
/// version on every poll; a mismatch is reported to the user rather than silently half-working.
pub const PROTOCOL: u32 = 1;

/// Re-exported so main.zig publishes the relay through the same module it registers the routes from. Called
/// once at boot, when the port is known.
pub const becomeHost = ext.becomeHost;

/// GET /api/v1/browser/ext/hello → who is listening here. UNAUTHENTICATED on purpose: this is the probe the
/// extension sweeps a handful of loopback ports with to find the server, before it has any credential at all.
/// It answers with nothing that isn't already implied by the port being open.
pub fn hello(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;
    try res.json(.{ .ok = true, .app = "nl-veil", .protocol = PROTOCOL }, .{});
}

/// True if this request came from the loopback interface. httpz reports the peer address; anything that is not
/// 127.0.0.0/8 or ::1 is off-box by definition, and a proxy in front of the server cannot forge it because
/// this reads the SOCKET, not a header (X-Forwarded-For is attacker-controlled and is deliberately ignored).
fn fromLoopback(req: *httpz.Request) bool {
    return switch (req.address) {
        // The WHOLE 127.0.0.0/8 block, not just 127.0.0.1 — every address in it is loopback-only by RFC 1122,
        // and a client that bound 127.0.0.2 is no less on-box.
        .ip4 => |v4| v4.bytes[0] == 127,
        .ip6 => |v6| blk: {
            const b = v6.bytes;
            const is_v6_loopback = std.mem.eql(u8, &b, &([_]u8{0} ** 15 ++ [_]u8{1})); // ::1
            // ::ffff:127.x.x.x — how a dual-stack listener reports a v4 loopback peer.
            const is_v4_mapped = std.mem.eql(u8, b[0..12], &([_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff })) and b[12] == 127;
            break :blk is_v6_loopback or is_v4_mapped;
        },
    };
}

/// POST /api/v1/browser/ext/pair → {ok:true, token}. LOOPBACK ONLY. Idempotent: the same process always
/// returns the same token, so re-pairing after a browser restart never orphans a live extension.
pub fn pair(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!fromLoopback(req)) {
        res.status = 403;
        try res.json(.{ .ok = false, .err = "browser pairing is only available from this machine" }, .{});
        return;
    }
    const token = ext.ensureToken(app.io);
    try res.json(.{ .ok = true, .token = token, .protocol = PROTOCOL }, .{});
}

/// The bearer every relay route requires. Answers 401 itself and returns false when it is missing or wrong.
fn requireExt(app: *App, req: *httpz.Request, res: *httpz.Response) bool {
    const h = req.header("x-veil-ext-token") orelse "";
    if (ext.tokenOk(app.io, std.mem.trim(u8, h, " "))) return true;
    res.status = 401;
    res.json(.{ .ok = false, .err = "pair first" }, .{}) catch {};
    return false;
}

/// GET /api/v1/browser/ext/poll?browser=edge&version=0.1.0&paused=0
/// → {ok:true, cmds:[{id,method,params,sessionId}, …]}
///
/// Blocks up to ext.POLL_MAX_MS waiting for work. An empty batch is the normal idle answer, and the extension
/// re-polls immediately — that continuous in-flight fetch is also what keeps the MV3 service worker alive.
pub fn poll(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!requireExt(app, req, res)) return;

    var browser: []const u8 = "";
    var version: []const u8 = "";
    var paused = false;
    if (req.query()) |q| {
        browser = q.get("browser") orelse "";
        version = q.get("version") orelse "";
        if (q.get("paused")) |p| paused = !std.mem.eql(u8, p, "0") and !std.ascii.eqlIgnoreCase(p, "false");
    } else |_| {}
    ext.heartbeat(app.io, browser, version, paused);

    // A PAUSED extension still polls — that is how the pause lifts without the user touching anything — but it
    // must not be handed work. Returning at once (rather than holding the poll open) keeps the pause responsive.
    const cmds = if (paused) try res.arena.dupe(u8, "[]") else ext.takeCommands(res.arena, app.io, ext.POLL_MAX_MS);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"cmds\":{s}}}", .{cmds});
}

const Result = struct {
    id: u64 = 0,
    result: ?std.json.Value = null,
    err: []const u8 = "",
};

/// POST /api/v1/browser/ext/result {id, result} | {id, err}
/// Hands one command's reply back to whichever thread is blocked in ext.call.
pub fn result(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!requireExt(app, req, res)) return;
    const body = req.body() orelse return http.badReq(res, "empty body");
    const p = std.json.parseFromSlice(Result, res.arena, body, .{ .ignore_unknown_fields = true }) catch
        return http.badReq(res, "bad json");
    if (p.value.id == 0) return http.badReq(res, "need id");

    const failed = p.value.err.len > 0;
    const payload = if (failed)
        try res.arena.dupe(u8, p.value.err)
    else if (p.value.result) |v|
        std.json.Stringify.valueAlloc(res.arena, v, .{}) catch return http.serverErr(res, "oom")
    else
        try res.arena.dupe(u8, "{}"); // a CDP command with no return value still completed

    // `delivered:false` is not an error — it means the waiter already timed out and moved on, and the
    // extension should simply drop it rather than retry into a slot that no longer exists.
    const delivered = ext.deliver(app.gpa, app.io, p.value.id, payload, failed);
    try res.json(.{ .ok = true, .delivered = delivered }, .{});
}

/// POST /api/v1/browser/ext/bye — the browser is closing or the user unhooked it. Fails every in-flight
/// command straight away instead of making each one wait out its own deadline.
pub fn bye(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!requireExt(app, req, res)) return;
    ext.disconnect(app.io);
    try res.json(.{ .ok = true }, .{});
}

// ------------------------------------------------------------------------------------ the cross-process relay
//
// The extension attaches to THIS process, but the browser tools do not all run here — the desk delegates each
// one to a `veil exec-tool` subprocess that forwards to the per-machine local-host daemon. Those processes
// find us through the discovery file ext.becomeHost writes at boot, and reach the extension through the two
// routes below. The credential is the same relay token, which lives only in a local-temp file — so this is
// exactly the trust boundary host.zig's daemon token already established, not a new one.

const Relayed = struct {
    token: []const u8 = "",
    method: []const u8 = "",
    params: std.json.Value = .null,
    sessionId: ?[]const u8 = null,
    timeout_ms: u32 = 30_000,
};

/// Body-borne variant of requireExt, for the two routes another veil process calls (httpc has no custom
/// headers, and the daemon/broker pattern in this tree already carries its token in the JSON body).
fn requireExtBody(app: *App, tok: []const u8, res: *httpz.Response) bool {
    if (ext.tokenOk(app.io, std.mem.trim(u8, tok, " "))) return true;
    res.status = 401;
    res.json(.{ .ok = false, .err = "bad relay token" }, .{}) catch {};
    return false;
}

/// POST /api/v1/browser/ext/live {token} → is the extension attached here and un-paused?
pub fn live(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse return http.badReq(res, "empty body");
    const T = struct { token: []const u8 = "" };
    const p = std.json.parseFromSlice(T, res.arena, body, .{ .ignore_unknown_fields = true }) catch
        return http.badReq(res, "bad json");
    if (!requireExtBody(app, p.value.token, res)) return;
    const st = ext.status(app.io);
    try res.json(.{ .ok = true, .connected = st.connected, .paused = st.paused, .browser = st.browser }, .{});
}

/// POST /api/v1/browser/ext/relay {token, method, params, sessionId, timeout_ms}
/// Run one CDP command on our extension on another process's behalf and hand back its result.
pub fn relay(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse return http.badReq(res, "empty body");
    const p = std.json.parseFromSlice(Relayed, res.arena, body, .{ .ignore_unknown_fields = true }) catch
        return http.badReq(res, "bad json");
    if (!requireExtBody(app, p.value.token, res)) return;
    if (p.value.method.len == 0) return http.badReq(res, "need method");

    const params = std.json.Stringify.valueAlloc(res.arena, p.value.params, .{}) catch return http.serverErr(res, "oom");
    const out = ext.callLocal(app.gpa, app.io, p.value.method, if (std.mem.eql(u8, params, "null")) "{}" else params, p.value.sessionId, p.value.timeout_ms) catch |e| {
        // A relayed failure is a NORMAL answer, not a 500: the caller falls back to launching its own
        // browser, and turning this into a server error would only obscure why.
        try res.json(.{ .ok = false, .err = @errorName(e) }, .{});
        return;
    };
    defer app.gpa.free(out);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"result\":{s}}}", .{if (out.len == 0) "{}" else out});
}

/// GET /api/v1/browser/ext/status → what the desk's settings panel and the web UI show. Authenticated as a
/// normal user: it reports whether this machine has a browser attached, which is the user's own business.
pub fn status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireUser(app, req, res) orelse return;
    const st = ext.status(app.io);
    try res.json(.{
        .ok = true,
        .connected = st.connected,
        .paused = st.paused,
        .browser = st.browser,
        .version = st.version,
        .idle_ms = st.idle_ms,
        .protocol = PROTOCOL,
    }, .{});
}

// ---------------------------------------------------------------------------
// tests — these routes are the ONLY unauthenticated-by-cookie surface added to the server, so the tests are
// about the door, not the plumbing: who may pair, who may relay, and what a malformed extension can make the
// server do. Command-lifecycle correctness lives in ext.zig's own tests. Handler-level throughout
// (harness/TESTING.md): http.testApp + httpz.testing, no extracted helpers.
// ---------------------------------------------------------------------------

/// TEST ONLY. Point the request at an address the handler will read as remote or loopback.
fn setPeer(web: anytype, ip: [4]u8, port: u16) void {
    web.req.address = .{ .ip4 = .{ .bytes = ip, .port = port } };
}

test "pair is loopback-only, and the token it mints is the one the relay accepts" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-extapi-pair-tmp");
    defer ta.deinit();

    // OFF-BOX: refused. This is the entire access-control story for the relay, so it is asserted first and
    // asserted on the SOCKET address — not on a header a caller could set.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        setPeer(&web, .{ 203, 0, 113, 7 }, 51000);
        try pair(&ta.app, web.req, web.res);
        try web.expectStatus(403);
        try std.testing.expect(std.mem.indexOf(u8, try web.getBody(), "token") == null); // and it leaks nothing
    }

    // ON-BOX: paired, and pairing twice returns the SAME token (a browser restart must not orphan a live
    // extension by rotating the credential out from under it).
    var token: [64]u8 = undefined;
    var token_len: usize = 0;
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        setPeer(&web, .{ 127, 0, 0, 1 }, 51000);
        try pair(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        const p = try std.json.parseFromSlice(std.json.Value, gpa, try web.getBody(), .{});
        defer p.deinit();
        const t = p.value.object.get("token").?.string;
        token_len = t.len;
        @memcpy(token[0..token_len], t);
        try std.testing.expectEqual(@as(usize, 32), token_len);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        setPeer(&web, .{ 127, 0, 0, 1 }, 51001);
        try pair(&ta.app, web.req, web.res);
        const p = try std.json.parseFromSlice(std.json.Value, gpa, try web.getBody(), .{});
        defer p.deinit();
        try std.testing.expectEqualStrings(token[0..token_len], p.value.object.get("token").?.string);
    }

    // The minted token is what /poll accepts...
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("x-veil-ext-token", token[0..token_len]);
        web.query("browser", "chrome");
        web.query("paused", "1"); // paused ⇒ returns immediately, so the test does not sit through a long poll
        try poll(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expect(std.mem.indexOf(u8, try web.getBody(), "\"cmds\":[]") != null);
    }
    // ...and it is the ONLY thing /poll accepts.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("x-veil-ext-token", "0123456789abcdef0123456789abcdef");
        try poll(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    ext.disconnect(io);
}

test "every relay route refuses an unpaired caller — no token, wrong token, empty token" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-extapi-gate-tmp");
    defer ta.deinit();

    const creds = [_]?[]const u8{ null, "", "not-the-token", "0123456789abcdef0123456789abcdef" };
    for (creds) |c| {
        {
            var web = httpz.testing.init(.{});
            defer web.deinit();
            if (c) |v| web.header("x-veil-ext-token", v);
            try poll(&ta.app, web.req, web.res);
            try web.expectStatus(401);
        }
        {
            var web = httpz.testing.init(.{});
            defer web.deinit();
            if (c) |v| web.header("x-veil-ext-token", v);
            web.body("{\"id\":1,\"result\":{}}");
            try result(&ta.app, web.req, web.res);
            try web.expectStatus(401);
        }
        {
            var web = httpz.testing.init(.{});
            defer web.deinit();
            if (c) |v| web.header("x-veil-ext-token", v);
            try bye(&ta.app, web.req, web.res);
            try web.expectStatus(401);
        }
    }
    // And an unauthenticated caller cannot read the machine's browser status either.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try status(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    // hello() is the one intentional exception — it must answer before any credential exists, or the
    // extension can never find the server in the first place.
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try hello(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expect(std.mem.indexOf(u8, try web.getBody(), "nl-veil") != null);
    }
    ext.disconnect(io);
}

test "a paired but malformed /result is rejected, not crashed into" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-extapi-result-tmp");
    defer ta.deinit();

    const token = ext.ensureToken(io);
    var tbuf: [32]u8 = undefined;
    @memcpy(&tbuf, token);

    // The extension is on the far side of a browser, i.e. is exactly as trustworthy as whatever is running in
    // it. Everything it can send that is not a well-formed result must land as a 400.
    const bad = [_][]const u8{
        "", // no body at all
        "not json",
        "{}", // no id
        "{\"id\":0,\"result\":{}}", // id 0 is the "unset" sentinel and must never match a slot
        "[1,2,3]", // valid JSON, wrong shape
        "{\"id\":1,\"result\":", // truncated mid-value (a reply cut off by a closing browser)
    };
    for (bad) |b| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("x-veil-ext-token", &tbuf);
        if (b.len > 0) web.body(b);
        try result(&ta.app, web.req, web.res);
        if (web.res.status != 400) {
            std.debug.print("\nmalformed /result body {s} answered {d}, not 400\n", .{ b, web.res.status });
            return error.MalformedResultAccepted;
        }
    }

    // A well-formed reply for a command nobody is waiting on is a 200 with delivered:false — the waiter timed
    // out, and the extension must be told to drop it rather than retry forever into a dead slot. The quoted
    // id is here on purpose: std.json COERCES `"987654"` to the integer field, so an extension that stringifies
    // its ids still routes correctly. That is leniency in the parser, not in the relay — the id still has to
    // match a live slot to deliver anything, which is the only property that matters.
    for ([_][]const u8{ "{\"id\":987654,\"result\":{\"value\":1}}", "{\"id\":\"987654\",\"result\":{}}" }) |b| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("x-veil-ext-token", &tbuf);
        web.body(b);
        try result(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expect(std.mem.indexOf(u8, try web.getBody(), "\"delivered\":false") != null);
    }
    ext.disconnect(io);
}
