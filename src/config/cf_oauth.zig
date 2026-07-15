//! cf_oauth.zig — "Log in with Cloudflare" for Workers AI, via Cloudflare's self-managed OAuth clients.
//!
//! FLOW (Authorization Code + PKCE, public client — no secret): the desk calls POST .../start; we mint a
//! CSRF `state` + a PKCE verifier/challenge, remember them, and hand back the Cloudflare consent URL. The desk
//! opens the system browser to it. The user grants access; Cloudflare redirects the browser to
//! GET .../callback?code&state on THIS server; we match the state, exchange the code (+ verifier) for an
//! access + refresh token, resolve the account id, and seal the bundle in the key vault under one uid. The
//! desk polls .../status and, once connected, drives Workers AI with no pasted key — the chat/cast paths
//! resolve the (auto-refreshed) token from the vault.
//!
//! Config is env-overridable (main.zig) so a deployment registers its OWN OAuth client and bakes only its
//! public client_id in. Disabled (start returns 501) until cf_oauth_client_id is set.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const key_vault = @import("key_vault.zig");
const App = http.App;
const requireUser = http.requireUser;

/// Compiled-in default OAuth client id, so "Log in with Cloudflare" works out of the box with no env var —
/// set this to the project's own PUBLIC OAuth client (register it once in the Cloudflare dashboard:
/// Manage Account → OAuth clients → Create client → Public/PKCE, verify the client URL's domain to make it
/// public, add the redirect http://localhost:8787/api/v1/oauth/cloudflare/callback). NL_CF_OAUTH_CLIENT_ID
/// still overrides it. Empty here = the login stays "not set up" until an env var or this constant is filled.
pub const DEFAULT_CLIENT_ID = "";

/// Vault provider slot for the sealed OAuth bundle — distinct from the "workers-ai" slot a manually pasted
/// BYOK key would use, so the two never collide.
pub const CF_PROVIDER = "cf-oauth";

/// Refresh the access token when it is within this many seconds of expiring (or already expired).
const REFRESH_SKEW_S: i64 = 120;

// ---------------------------------------------------------------- pending-auth store (state -> PKCE + uid)

const Pending = struct {
    state: [48]u8 = undefined,
    state_len: usize = 0,
    verifier: [64]u8 = undefined,
    verifier_len: usize = 0,
    uid: u64 = 0,
    created_s: i64 = 0,
};

const MAX_PENDING = 16;
const PENDING_TTL_S: i64 = 600; // a consent flow the user never finishes ages out in 10 min

var pending_mtx: std.Io.Mutex = .init;
var pending: [MAX_PENDING]Pending = undefined;
var pending_init = false;

fn nowS(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Claim a slot for a fresh flow (reuses the oldest expired slot when full). Copies state+verifier in.
fn storePending(io: std.Io, state: []const u8, verifier: []const u8, uid: u64) void {
    pending_mtx.lockUncancelable(io);
    defer pending_mtx.unlock(io);
    if (!pending_init) {
        for (&pending) |*p| p.* = .{};
        pending_init = true;
    }
    const now = nowS(io);
    var slot: usize = 0;
    var oldest: i64 = std.math.maxInt(i64);
    for (&pending, 0..) |*p, i| {
        if (p.state_len == 0 or now - p.created_s > PENDING_TTL_S) {
            slot = i;
            break;
        }
        if (p.created_s < oldest) {
            oldest = p.created_s;
            slot = i;
        }
    }
    var p = &pending[slot];
    p.state_len = @min(state.len, p.state.len);
    @memcpy(p.state[0..p.state_len], state[0..p.state_len]);
    p.verifier_len = @min(verifier.len, p.verifier.len);
    @memcpy(p.verifier[0..p.verifier_len], verifier[0..p.verifier_len]);
    p.uid = uid;
    p.created_s = now;
}

/// Consume the slot matching `state` (single-use). Returns the verifier + uid, or null (unknown/expired).
fn takePending(io: std.Io, state: []const u8, verifier_out: *[64]u8) ?struct { verifier_len: usize, uid: u64 } {
    pending_mtx.lockUncancelable(io);
    defer pending_mtx.unlock(io);
    if (!pending_init) return null;
    const now = nowS(io);
    for (&pending) |*p| {
        if (p.state_len == 0) continue;
        if (now - p.created_s > PENDING_TTL_S) {
            p.* = .{};
            continue;
        }
        if (std.mem.eql(u8, p.state[0..p.state_len], state)) {
            @memcpy(verifier_out[0..p.verifier_len], p.verifier[0..p.verifier_len]);
            const vlen = p.verifier_len;
            const uid = p.uid;
            p.* = .{}; // single-use
            return .{ .verifier_len = vlen, .uid = uid };
        }
    }
    return null;
}

// ------------------------------------------------------------------------------------ PKCE + encoding

const b64url = std.base64.url_safe_no_pad.Encoder;

/// A URL-safe random token of `raw_bytes` entropy (base64url, no padding). Used for the PKCE verifier + state.
fn randToken(io: std.Io, comptime raw_bytes: usize, out: []u8) usize {
    var raw: [raw_bytes]u8 = undefined;
    io.random(&raw);
    const n = b64url.calcSize(raw_bytes);
    _ = b64url.encode(out[0..n], &raw);
    return n;
}

/// PKCE S256 challenge = base64url(sha256(verifier)).
fn pkceChallenge(verifier: []const u8, out: *[43]u8) void {
    var dig: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &dig, .{});
    _ = b64url.encode(out, &dig);
}

/// Percent-encode `s` into `list` for use in a URL query / form body (RFC 3986 unreserved passes through).
fn pctEncode(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try list.append(gpa, c);
        } else {
            try list.append(gpa, '%');
            try list.append(gpa, hex[c >> 4]);
            try list.append(gpa, hex[c & 0x0F]);
        }
    }
}

// ------------------------------------------------------------------------------------ outbound HTTPS (curl)

/// One outbound HTTPS call to Cloudflare via curl. The request BODY (which may hold the short-lived code or the
/// refresh token) goes in a scratch file passed with --data-binary @file, never on the argv; a Bearer token, if
/// any, rides a curl config file (-K), also never on the argv. Returns the response body (gpa-owned) or null.
/// A random suffix keeps concurrent flows from sharing scratch paths.
fn curlCall(app: *App, method: []const u8, url: []const u8, form_body: []const u8, bearer: []const u8) ?[]u8 {
    const gpa = app.gpa;
    const io = app.io;
    var sfx: [8]u8 = undefined;
    io.random(&sfx);
    const tag = std.fmt.bytesToHex(sfx, .lower);

    var body_path_buf: [600]u8 = undefined;
    var cfg_path_buf: [600]u8 = undefined;
    const body_path = std.fmt.bufPrint(&body_path_buf, "{s}/.cfoauth-body-{s}", .{ app.data, tag }) catch return null;
    const cfg_path = std.fmt.bufPrint(&cfg_path_buf, "{s}/.cfoauth-cfg-{s}", .{ app.data, tag }) catch return null;
    var wrote_body = false;
    var wrote_cfg = false;
    defer if (wrote_body) std.Io.Dir.cwd().deleteFile(io, body_path) catch {};
    defer if (wrote_cfg) std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    if (form_body.len > 0) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = body_path, .data = form_body }) catch return null;
        wrote_body = true;
    }
    // curl config file carries the auth header + a content-type, so no secret lands on the argv.
    {
        var cfg: std.ArrayListUnmanaged(u8) = .empty;
        defer cfg.deinit(gpa);
        cfg.appendSlice(gpa, "silent\nshow-error\n") catch return null;
        if (bearer.len > 0) {
            cfg.appendSlice(gpa, "header = \"Authorization: Bearer ") catch return null;
            cfg.appendSlice(gpa, bearer) catch return null;
            cfg.appendSlice(gpa, "\"\n") catch return null;
        }
        if (form_body.len > 0)
            cfg.appendSlice(gpa, "header = \"Content-Type: application/x-www-form-urlencoded\"\n") catch return null;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = cfg.items }) catch return null;
        wrote_cfg = true;
    }

    var data_at_buf: [610]u8 = undefined;
    const data_at = std.fmt.bufPrint(&data_at_buf, "@{s}", .{body_path}) catch return null;
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sS", "--max-time", "30", "-X", method, "-K", cfg_path }) catch return null;
    if (form_body.len > 0) av.appendSlice(gpa, &.{ "--data-binary", data_at }) catch return null;
    av.append(gpa, url) catch return null;

    const run = std.process.run(gpa, io, .{ .argv = av.items, .stdout_limit = .limited(1 << 20) }) catch return null;
    gpa.free(run.stderr);
    if (run.stdout.len == 0) {
        gpa.free(run.stdout);
        return null;
    }
    return run.stdout;
}

// ------------------------------------------------------------------------------------ token exchange + resolve

const TokenResp = struct {
    access_token: []const u8 = "",
    refresh_token: []const u8 = "",
    expires_in: i64 = 0,
    token_type: []const u8 = "",
    @"error": []const u8 = "",
};

/// Exchange an authorization `code` (+ PKCE verifier) for tokens, or refresh with a `refresh_token`. `grant` is
/// "authorization_code" (needs code+verifier) or "refresh_token" (needs refresh). Returns owned copies of the
/// tokens + absolute expiry, or null on any failure.
fn exchange(app: *App, alloc: std.mem.Allocator, grant: []const u8, code: []const u8, verifier: []const u8, refresh: []const u8) ?key_vault.OAuthBundle {
    const gpa = app.gpa;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    body.appendSlice(gpa, "grant_type=") catch return null;
    body.appendSlice(gpa, grant) catch return null;
    body.appendSlice(gpa, "&client_id=") catch return null;
    pctEncode(gpa, &body, app.cf_oauth_client_id) catch return null;
    if (std.mem.eql(u8, grant, "authorization_code")) {
        body.appendSlice(gpa, "&code=") catch return null;
        pctEncode(gpa, &body, code) catch return null;
        body.appendSlice(gpa, "&code_verifier=") catch return null;
        pctEncode(gpa, &body, verifier) catch return null;
        body.appendSlice(gpa, "&redirect_uri=") catch return null;
        pctEncode(gpa, &body, app.cf_oauth_redirect) catch return null;
    } else {
        body.appendSlice(gpa, "&refresh_token=") catch return null;
        pctEncode(gpa, &body, refresh) catch return null;
    }

    const raw = curlCall(app, "POST", app.cf_oauth_token_url, body.items, "") orelse return null;
    defer gpa.free(raw);
    const parsed = std.json.parseFromSlice(TokenResp, gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.access_token.len == 0) return null;
    return .{
        .key = alloc.dupe(u8, parsed.value.access_token) catch return null,
        // A refresh response may omit refresh_token (keep the old one); the caller handles an empty value.
        .refresh_token = alloc.dupe(u8, parsed.value.refresh_token) catch "",
        .expires_at = nowS(app.io) + (if (parsed.value.expires_in > 0) parsed.value.expires_in else 3600),
        .account_id = "",
        .base_url = "",
    };
}

const AccountsResp = struct {
    result: []const struct { id: []const u8 = "" } = &.{},
    success: bool = false,
};

/// Resolve the user's Cloudflare account id with the access token (first account). Empty on failure.
fn fetchAccountId(app: *App, alloc: std.mem.Allocator, access: []const u8) []const u8 {
    var ub: [600]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}?per_page=1", .{app.cf_oauth_accounts_url}) catch return "";
    const raw = curlCall(app, "GET", url, "", access) orelse return "";
    defer app.gpa.free(raw);
    const parsed = std.json.parseFromSlice(AccountsResp, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return "";
    defer parsed.deinit();
    if (parsed.value.result.len == 0) return "";
    return alloc.dupe(u8, parsed.value.result[0].id) catch "";
}

/// Build the Workers AI OpenAI-compatible base_url for an account id.
fn workersAiBase(alloc: std.mem.Allocator, account_id: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc, "https://api.cloudflare.com/client/v4/accounts/{s}/ai/v1", .{account_id}) catch "";
}

/// The public entry the chat + cast paths use: return the CURRENT Workers AI access token + base_url for `uid`,
/// refreshing (and re-sealing) if it's within REFRESH_SKEW_S of expiry. null when the user isn't logged in via
/// OAuth (caller falls back to a pasted key / server env). `alloc` owns the returned strings.
pub fn resolveToken(app: *App, uid: u64, alloc: std.mem.Allocator) ?struct { key: []const u8, base_url: []const u8, account_id: []const u8 } {
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const b = app.vault.resolveOAuth(uid, CF_PROVIDER, sa) orelse return null;
    if (b.refresh_token.len == 0) return null; // not an OAuth bundle

    var access = b.key;
    var account = b.account_id;
    if (nowS(app.io) + REFRESH_SKEW_S >= b.expires_at) {
        // refresh in place: the refresh token may or may not rotate; keep the old one if the response omits it.
        if (exchange(app, sa, "refresh_token", "", "", b.refresh_token)) |fresh| {
            access = fresh.key;
            const new_refresh = if (fresh.refresh_token.len > 0) fresh.refresh_token else b.refresh_token;
            if (account.len == 0) account = fetchAccountId(app, sa, access);
            const base = workersAiBase(sa, account);
            app.vault.putOAuth(uid, CF_PROVIDER, access, new_refresh, fresh.expires_at, account, base) catch {};
        } else {
            // refresh failed (revoked / offline) — surface as not-connected so the caller falls back cleanly.
            return null;
        }
    }
    if (account.len == 0) return null;
    return .{
        .key = alloc.dupe(u8, access) catch return null,
        .base_url = alloc.dupe(u8, workersAiBase(alloc, account)) catch return null,
        .account_id = alloc.dupe(u8, account) catch "",
    };
}

// ------------------------------------------------------------------------------------ live model list

/// The Workers AI catalog changes fast, so the model list is fetched LIVE from the user's account rather
/// than hardcoded. Cached in-process (single desktop user) with a short TTL; the cache dies on restart, so
/// every server start refetches — "dynamic collection every time the machine turns on and connects".
const MODELS_TTL_S: i64 = 900; // 15 min
var models_mtx: std.Io.Mutex = .init;
var mc_uid: u64 = 0;
var mc_buf: [16384]u8 = undefined; // the built JSON array of model-name strings
var mc_len: usize = 0;
var mc_at: i64 = 0;

/// GET the account's text-generation Workers AI models and build a JSON array of their names
/// (e.g. `["@cf/meta/llama-3.3-70b-instruct-fp8-fast", …]`). null when not connected or the fetch fails.
fn fetchModelsList(app: *App, uid: u64, alloc: std.mem.Allocator) ?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const tok = resolveToken(app, uid, sa) orelse return null;
    if (tok.account_id.len == 0) return null;
    var ub: [700]u8 = undefined;
    // task filter narrows to chat models; hide_experimental drops preview entries; one generous page.
    const url = std.fmt.bufPrint(&ub, "{s}/{s}/ai/models/search?task=Text%20Generation&hide_experimental=true&per_page=100", .{ app.cf_oauth_accounts_url, tok.account_id }) catch return null;
    const raw = curlCall(app, "GET", url, "", tok.key) orelse return null;
    defer app.gpa.free(raw);
    const ModelsResp = struct {
        result: []const struct { name: []const u8 = "" } = &.{},
    };
    const parsed = std.json.parseFromSlice(ModelsResp, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.result.len == 0) return null; // no models parsed → let the caller keep the catalog defaults
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    out.append(app.gpa, '[') catch return null;
    var n: usize = 0;
    for (parsed.value.result) |m| {
        if (m.name.len == 0 or m.name.len > 120) continue;
        if (n > 0) out.append(app.gpa, ',') catch return null;
        http.jstr(app.gpa, &out, m.name) catch return null;
        n += 1;
    }
    out.append(app.gpa, ']') catch return null;
    if (n == 0) return null;
    return alloc.dupe(u8, out.items) catch null;
}

/// Cached model-list JSON array for `uid`. Serves a fresh cache; else refetches (and on a fetch failure,
/// falls back to a stale cache if one exists). alloc-owned copy, or null when there's nothing to serve.
fn modelsJson(app: *App, uid: u64, alloc: std.mem.Allocator) ?[]const u8 {
    const now = nowS(app.io);
    {
        models_mtx.lockUncancelable(app.io);
        defer models_mtx.unlock(app.io);
        if (mc_uid == uid and mc_len > 0 and now - mc_at < MODELS_TTL_S)
            return alloc.dupe(u8, mc_buf[0..mc_len]) catch null;
    }
    const fresh = fetchModelsList(app, uid, alloc) orelse {
        models_mtx.lockUncancelable(app.io);
        defer models_mtx.unlock(app.io);
        if (mc_uid == uid and mc_len > 0) return alloc.dupe(u8, mc_buf[0..mc_len]) catch null;
        return null;
    };
    models_mtx.lockUncancelable(app.io);
    defer models_mtx.unlock(app.io);
    if (fresh.len <= mc_buf.len) {
        @memcpy(mc_buf[0..fresh.len], fresh);
        mc_len = fresh.len;
        mc_uid = uid;
        mc_at = now;
    }
    return fresh;
}

/// GET /api/v1/oauth/cloudflare/models — the account's live Workers AI (text-generation) models. The desk
/// swaps this into its model dropdown for the Cloudflare provider, falling back to the catalog when empty.
pub fn models(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    res.content_type = .JSON;
    if (modelsJson(app, u.id, a)) |ml| {
        res.body = try std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"connected\":true,\"models\":{s}}}", .{ml});
    } else {
        res.body = "{\"ok\":true,\"connected\":false,\"models\":[]}";
    }
}

// ------------------------------------------------------------------------------------ HTTP handlers

/// POST /api/v1/oauth/cloudflare/start — mint state + PKCE, return the Cloudflare consent URL for the desk to
/// open. 501 when the feature isn't configured (no client_id). The uid rides the state so the (unauthenticated)
/// browser callback can be attributed back to this user.
pub fn start(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    if (app.cf_oauth_client_id.len == 0) {
        res.status = 501;
        try res.json(.{ .ok = false, .err = "Cloudflare OAuth is not configured on this server (set NL_CF_OAUTH_CLIENT_ID)" }, .{});
        return;
    }
    var vbuf: [64]u8 = undefined;
    const verifier_len = randToken(app.io, 32, &vbuf); // 32 raw bytes -> 43-char verifier (RFC 7636 range)
    const verifier = vbuf[0..verifier_len];
    var chal: [43]u8 = undefined;
    pkceChallenge(verifier, &chal);
    var sbuf: [48]u8 = undefined;
    const state_len = randToken(app.io, 24, &sbuf);
    const state = sbuf[0..state_len];
    storePending(app.io, state, verifier, u.id);

    const gpa = app.gpa;
    var url: std.ArrayListUnmanaged(u8) = .empty;
    defer url.deinit(gpa);
    try url.appendSlice(gpa, app.cf_oauth_auth_url);
    try url.appendSlice(gpa, "?response_type=code&client_id=");
    try pctEncode(gpa, &url, app.cf_oauth_client_id);
    try url.appendSlice(gpa, "&redirect_uri=");
    try pctEncode(gpa, &url, app.cf_oauth_redirect);
    try url.appendSlice(gpa, "&scope=");
    try pctEncode(gpa, &url, app.cf_oauth_scopes);
    try url.appendSlice(gpa, "&state=");
    try pctEncode(gpa, &url, state);
    try url.appendSlice(gpa, "&code_challenge=");
    try pctEncode(gpa, &url, chal[0..]);
    try url.appendSlice(gpa, "&code_challenge_method=S256");

    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"authorize_url\":\"{s}\",\"state\":\"{s}\"}}", .{ url.items, state });
}

/// GET /api/v1/oauth/cloudflare/callback?code&state — Cloudflare redirects the BROWSER here (unauthenticated);
/// the state maps back to the pending flow + uid. Exchange the code, resolve the account, seal the bundle, and
/// render a plain "you can close this tab" page. On any failure render a short error page (never 500 the user).
pub fn callback(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const q = try req.query();
    const code = q.get("code") orelse "";
    const state = q.get("state") orelse "";
    if (q.get("error")) |e| return page(res, false, e);
    if (code.len == 0 or state.len == 0) return page(res, false, "missing code/state");

    var vbuf: [64]u8 = undefined;
    const pend = takePending(app.io, state, &vbuf) orelse return page(res, false, "unknown or expired login (state mismatch) — start again from veil-desk");
    const verifier = vbuf[0..pend.verifier_len];

    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const tok = exchange(app, a, "authorization_code", code, verifier, "") orelse return page(res, false, "token exchange failed — check the client_id / redirect URI registered on Cloudflare");
    const account = fetchAccountId(app, a, tok.key);
    if (account.len == 0) return page(res, false, "could not read your Cloudflare account (the token may lack account:read)");
    const base = workersAiBase(a, account);
    app.vault.putOAuth(pend.uid, CF_PROVIDER, tok.key, tok.refresh_token, tok.expires_at, account, base) catch
        return page(res, false, "could not store the credential");
    return page(res, true, account);
}

/// GET /api/v1/oauth/cloudflare/status — the desk polls this: is the feature configured, and is THIS user
/// connected (and to which account)? Never returns the token.
pub fn status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const configured = app.cf_oauth_client_id.len > 0;
    var connected = false;
    var account: []const u8 = "";
    var expires_at: i64 = 0;
    if (app.vault.resolveOAuth(u.id, CF_PROVIDER, a)) |b| {
        if (b.refresh_token.len > 0) {
            connected = true;
            account = b.account_id;
            expires_at = b.expires_at;
        }
    }
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"configured\":{},\"connected\":{},\"account_id\":\"{s}\",\"expires_at\":{d}}}", .{ configured, connected, account, expires_at });
}

/// POST /api/v1/oauth/cloudflare/logout — forget this user's stored Cloudflare credential.
pub fn logout(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    app.vault.del(u.id, CF_PROVIDER);
    try res.json(.{ .ok = true, .disconnected = true }, .{});
}

/// Render the post-callback browser page (the only HTML this module returns).
fn page(res: *httpz.Response, ok: bool, detail: []const u8) !void {
    res.content_type = .HTML;
    res.status = if (ok) 200 else 400;
    const title = if (ok) "Connected to Cloudflare" else "Cloudflare login failed";
    const msg = if (ok) "You're connected. You can close this tab and return to veil-desk." else "Something went wrong.";
    res.body = try std.fmt.allocPrint(res.arena,
        \\<!doctype html><meta charset="utf-8"><title>{s}</title>
        \\<div style="font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:16vh auto;padding:0 1rem;color:#1a1b26">
        \\<h2 style="color:{s}">{s}</h2><p>{s}</p><p style="color:#565f89;font-size:14px">{s}</p></div>
    , .{ title, if (ok) "#2ac3de" else "#f7768e", title, msg, detail });
}

test "pkce challenge is base64url sha256 of the verifier" {
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"; // RFC 7636 example verifier
    var chal: [43]u8 = undefined;
    pkceChallenge(verifier, &chal);
    // RFC 7636 appendix B expected challenge
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &chal);
}

test "pctEncode leaves unreserved, encodes the rest" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(gpa);
    try pctEncode(gpa, &list, "a b/c:d_-~");
    try std.testing.expectEqualStrings("a%20b%2Fc%3Ad_-~", list.items);
}

test "pending store round-trips state->verifier and is single-use" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // reset shared state for a deterministic test
    pending_mtx.lockUncancelable(io);
    for (&pending) |*p| p.* = .{};
    pending_init = true;
    pending_mtx.unlock(io);

    storePending(io, "STATE123", "VERIFIERXYZ", 7);
    var vbuf: [64]u8 = undefined;
    const got = takePending(io, "STATE123", &vbuf) orelse return error.NotFound;
    try std.testing.expectEqual(@as(u64, 7), got.uid);
    try std.testing.expectEqualStrings("VERIFIERXYZ", vbuf[0..got.verifier_len]);
    try std.testing.expect(takePending(io, "STATE123", &vbuf) == null); // consumed
}
