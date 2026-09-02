//! cf_oauth.zig — "Log in with Cloudflare" for Workers AI, via Cloudflare's self-managed OAuth clients.
//!
//! FLOW (Authorization Code + PKCE, public client — no secret): a client (desk or web app) calls POST
//! .../start; we mint a CSRF `state` + a PKCE verifier/challenge, remember them, and hand back the Cloudflare
//! consent URL. The client opens the browser to it. The user grants access; Cloudflare redirects the browser
//! to GET .../callback?code&state on THIS server; we match the state, exchange the code (+ verifier) for an
//! access + refresh token, resolve the account (id AND display name) plus the user's own name/email, seal the
//! bundle in the key vault under one uid, and write the non-secret profile beside the user's data. Clients
//! poll .../status (which carries the profile) and, once connected, drive Workers AI with no pasted key —
//! the chat/cast/sched paths resolve the (auto-refreshed) token from the vault. A successful login also
//! kicks cf_r2 (the R2 chat/data backup) into provisioning the user's bucket.
//!
//! Config is env-overridable (main.zig) so a deployment registers its OWN OAuth client and bakes only its
//! public client_id in. Disabled (start returns 501) until cf_oauth_client_id is set.

const std = @import("std");
const bu = @import("../worker/browser/util.zig"); // sleepMs: a raw-thread sleep, no Io park
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const key_vault = @import("key_vault.zig");
const cf_r2 = @import("cf_r2.zig");
const App = http.App;
const requireUser = http.requireUser;

/// Compiled-in default OAuth client id, so "Log in with Cloudflare" works out of the box with no env var.
/// This is the project's own registered client ("nl-veil", registered 2026-08-30 in the project account) —
/// a PUBLIC IDENTIFIER, not a secret: every open-source CLI with a browser login (wrangler, gh, Claude
/// Code) ships its client id in the open exactly like this. Users authorize their OWN Cloudflare accounts
/// through it; the id only names the app on the consent screen and pins the redirect allowlist.
///
/// The registration recipe, should it ever need re-creating (dashboard → Manage Account → OAuth clients):
/// response_type Code; grant types Authorization Code AND Refresh Token (without the second, the
/// offline_access scope is refused and logins die at first token expiry); token auth method None (PKCE);
/// redirect http://localhost:8787/api/v1/oauth/cloudflare/callback; scopes exactly the six catalog
/// permissions in http.CF_OAUTH_SCOPES_DEFAULT. The client starts PRIVATE (only the owning account can
/// authorize — fine for testing); flip visibility to public (one-time DNS TXT domain verification,
/// permanent) before telling the world. A scope change after launch forces every connected user through
/// consent again. NL_CF_OAUTH_CLIENT_ID still overrides this constant.
pub const DEFAULT_CLIENT_ID = "80bc327e23e901c0f92273853011e007";

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
///
/// pub, with the content type as a parameter, because this is the ONE Cloudflare HTTP path in the process:
/// cf_r2 reuses it for bucket/object calls (JSON and raw octet-stream bodies) rather than growing a second
/// curl wrapper with its own secret-handling mistakes.
pub fn apiCall(app: *App, method: []const u8, url: []const u8, body: []const u8, bearer: []const u8, content_type: []const u8) ?[]u8 {
    return curlCallCt(app, method, url, body, bearer, content_type);
}

/// The token/consent legs all speak forms; keep their call sites one argument shorter.
fn curlCall(app: *App, method: []const u8, url: []const u8, form_body: []const u8, bearer: []const u8) ?[]u8 {
    return curlCallCt(app, method, url, form_body, bearer, "application/x-www-form-urlencoded");
}

fn curlCallCt(app: *App, method: []const u8, url: []const u8, form_body: []const u8, bearer: []const u8, content_type: []const u8) ?[]u8 {
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
        if (form_body.len > 0) {
            cfg.appendSlice(gpa, "header = \"Content-Type: ") catch return null;
            cfg.appendSlice(gpa, content_type) catch return null;
            cfg.appendSlice(gpa, "\"\n") catch return null;
        }
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
    result: []const struct { id: []const u8 = "", name: []const u8 = "" } = &.{},
    success: bool = false,
};

const AccountInfo = struct { id: []const u8 = "", name: []const u8 = "" };

/// Resolve the user's Cloudflare account (first account: id + display name) with the access token.
/// Empty fields on failure — the id is the load-bearing one, the name is presentation.
fn fetchAccount(app: *App, alloc: std.mem.Allocator, access: []const u8) AccountInfo {
    var ub: [600]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}?per_page=1", .{app.cf_oauth_accounts_url}) catch return .{};
    const raw = curlCall(app, "GET", url, "", access) orelse return .{};
    defer app.gpa.free(raw);
    const parsed = std.json.parseFromSlice(AccountsResp, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    if (parsed.value.result.len == 0) return .{};
    return .{
        .id = alloc.dupe(u8, parsed.value.result[0].id) catch "",
        .name = alloc.dupe(u8, parsed.value.result[0].name) catch "",
    };
}

/// The API root the accounts URL hangs off ("https://api.cloudflare.com/client/v4"), so /user can be
/// derived instead of configured twice. Falls back to the accounts URL itself if the suffix is absent.
fn apiRoot(app: *App) []const u8 {
    const suffix = "/accounts";
    const u = app.cf_oauth_accounts_url;
    if (std.mem.endsWith(u8, u, suffix)) return u[0 .. u.len - suffix.len];
    return u;
}

const UserResp = struct {
    result: struct { email: []const u8 = "", first_name: ?[]const u8 = null, last_name: ?[]const u8 = null } = .{},
    success: bool = false,
};

const UserInfo = struct { email: []const u8 = "", name: []const u8 = "" };

/// The user's own email + display name via GET /user. Needs the user-details.read scope; a token
/// granted without it (older consent, trimmed client) just yields empty fields — profile display
/// degrades to the account name, nothing else depends on this.
fn fetchUserInfo(app: *App, alloc: std.mem.Allocator, access: []const u8) UserInfo {
    var ub: [600]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}/user", .{apiRoot(app)}) catch return .{};
    const raw = curlCall(app, "GET", url, "", access) orelse return .{};
    defer app.gpa.free(raw);
    const parsed = std.json.parseFromSlice(UserResp, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    const r = parsed.value.result;
    const first = r.first_name orelse "";
    const last = r.last_name orelse "";
    const name = if (first.len > 0 and last.len > 0)
        std.fmt.allocPrint(alloc, "{s} {s}", .{ first, last }) catch ""
    else if (first.len > 0)
        alloc.dupe(u8, first) catch ""
    else
        alloc.dupe(u8, last) catch "";
    return .{ .email = alloc.dupe(u8, r.email) catch "", .name = name };
}

// ------------------------------------------------------------------------------------ profile (non-secret)

/// What the UIs show for "signed in as": account id/name + the user's name/email. NOT a credential —
/// the tokens stay sealed in the vault; this is presentation data and lives as plain JSON in the
/// user's own data dir, written at login, deleted at logout.
pub const Profile = struct {
    account_id: []const u8 = "",
    account_name: []const u8 = "",
    email: []const u8 = "",
    user_name: []const u8 = "",
};

fn profilePath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/cf_profile.json", .{ app.data, uid }) catch null;
}

fn writeProfile(app: *App, uid: u64, p: Profile) void {
    var pb: [600]u8 = undefined;
    const path = profilePath(app, uid, &pb) orelse return;
    // the user dir may not exist yet — a brand-new account can log into Cloudflare before its first turn
    var db: [600]u8 = undefined;
    if (std.fmt.bufPrint(&db, "{s}/u{d}", .{ app.data, uid })) |dir| {
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    } else |_| {}
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    out.appendSlice(app.gpa, "{\"account_id\":") catch return;
    http.jstr(app.gpa, &out, p.account_id) catch return;
    out.appendSlice(app.gpa, ",\"account_name\":") catch return;
    http.jstr(app.gpa, &out, p.account_name) catch return;
    out.appendSlice(app.gpa, ",\"email\":") catch return;
    http.jstr(app.gpa, &out, p.email) catch return;
    out.appendSlice(app.gpa, ",\"user_name\":") catch return;
    http.jstr(app.gpa, &out, p.user_name) catch return;
    out.append(app.gpa, '}') catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// The stored profile for `uid`, or null when none exists (never logged in, or logged out). `alloc`
/// owns the strings.
pub fn readProfile(app: *App, uid: u64, alloc: std.mem.Allocator) ?Profile {
    var pb: [600]u8 = undefined;
    const path = profilePath(app, uid, &pb) orelse return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(16384)) catch return null;
    defer app.gpa.free(raw);
    const parsed = std.json.parseFromSlice(Profile, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return .{
        .account_id = alloc.dupe(u8, parsed.value.account_id) catch return null,
        .account_name = alloc.dupe(u8, parsed.value.account_name) catch "",
        .email = alloc.dupe(u8, parsed.value.email) catch "",
        .user_name = alloc.dupe(u8, parsed.value.user_name) catch "",
    };
}

fn deleteProfile(app: *App, uid: u64) void {
    var pb: [600]u8 = undefined;
    const path = profilePath(app, uid, &pb) orelse return;
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
}

/// Build the Workers AI OpenAI-compatible base_url for an account id.
fn workersAiBase(alloc: std.mem.Allocator, account_id: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc, "https://api.cloudflare.com/client/v4/accounts/{s}/ai/v1", .{account_id}) catch "";
}

/// Refreshes are SERIALIZED: chat turns, casts, scheduled runs, the model-list fetch and the R2 sync
/// thread can all hit the expiry window together, and two concurrent refresh grants with one stored
/// refresh_token means the loser fails — and under refresh-token-rotation-with-reuse-detection can
/// revoke the whole grant. One mutex, held across the exchange; the winner re-seals, the vault write
/// drops its own resolve-cache entry, and everyone queued behind re-reads the fresh bundle.
/// ONE refresh in flight at a time, and NOBODY QUEUES BEHIND IT WITH A LIVE TOKEN. This was a mutex: every
/// caller inside the skew window took it and, finding the token still due, ran its own 30 s exchange. When
/// Cloudflare's token endpoint went slow on 2026-09-02, every token consumer - three resolveRole calls per
/// chat message, the desk's status/tunnel/r2 polls - formed a queue of 30 s attempts: the desk timed out
/// for four minutes and a chat turn's POST was answered after 210 s. The token they were all waiting for
/// was still valid the whole time.
var refreshing: std.atomic.Value(bool) = .init(false);
/// Wall time of the last refresh that FAILED (0 = none). While it is recent, callers with a live token use
/// it instead of hammering an endpoint that just said no; an expired token still forces a fresh attempt.
var refresh_fail_s: std.atomic.Value(i64) = .init(0);
const REFRESH_RETRY_S: i64 = 45;
/// How long an EXPIRED caller waits for another thread's in-flight refresh before re-reading the vault.
const REFRESH_WAIT_MS: u32 = 35_000;

/// What resolveToken hands out: the live access token, the account's Workers AI base and the account id.
pub const Token = struct { key: []const u8, base_url: []const u8, account_id: []const u8 };

const RefreshPlan = enum { use, refresh, wait };

/// The decision, pure so it is testable: given the clock, the token's expiry, when a refresh last failed and
/// whether one is in flight - use what we hold, run a refresh ourselves, or (expired only) wait for the one
/// in flight.
fn refreshPlan(now: i64, expires_at: i64, last_fail: i64, busy: bool) RefreshPlan {
    if (now + REFRESH_SKEW_S < expires_at) return .use; // not due yet
    const live = now < expires_at;
    if (live and last_fail > 0 and now - last_fail < REFRESH_RETRY_S) return .use; // it just failed; do not pile on
    if (busy) return if (live) .use else .wait;
    return .refresh;
}

/// The public entry the chat + cast paths use: return the CURRENT Workers AI access token + base_url for `uid`,
/// refreshing (and re-sealing) if it's within REFRESH_SKEW_S of expiry. null when the user isn't logged in via
/// OAuth (caller falls back to a pasted key / server env). `alloc` owns the returned strings.
pub fn resolveToken(app: *App, uid: u64, alloc: std.mem.Allocator) ?Token {
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var b = app.vault.resolveOAuth(uid, CF_PROVIDER, sa) orelse return null;
    if (b.refresh_token.len == 0) return null; // not an OAuth bundle

    var access = b.key;
    var account = b.account_id;
    const now0 = nowS(app.io);
    switch (refreshPlan(now0, b.expires_at, refresh_fail_s.load(.monotonic), refreshing.load(.acquire))) {
        .use => {},
        .wait => {
            // EXPIRED, and another thread is refreshing right now: wait for it (bounded, on a raw-thread
            // sleep - never a park on the Io runtime), then take whatever it produced.
            var waited: u32 = 0;
            while (refreshing.load(.acquire) and waited < REFRESH_WAIT_MS) : (waited += 100) bu.sleepMs(100);
            b = app.vault.resolveOAuth(uid, CF_PROVIDER, sa) orelse return null;
            if (nowS(app.io) >= b.expires_at) return null; // still expired: not connected, the caller falls back
            access = b.key;
            account = b.account_id;
        },
        .refresh => {
            if (refreshing.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
                // Lost the race to another refresher. A live token is used as is; an expired one waits.
                if (now0 < b.expires_at) return finishToken(alloc, access, account);
                var waited: u32 = 0;
                while (refreshing.load(.acquire) and waited < REFRESH_WAIT_MS) : (waited += 100) bu.sleepMs(100);
                b = app.vault.resolveOAuth(uid, CF_PROVIDER, sa) orelse return null;
                if (nowS(app.io) >= b.expires_at) return null;
                return finishToken(alloc, b.key, b.account_id);
            }
            defer refreshing.store(false, .release);
            // Re-read after claiming: a refresh may have landed between our first read and the claim (putOAuth
            // drops the vault's cached entry, so this observes the fresh bundle, not a stale cache).
            b = app.vault.resolveOAuth(uid, CF_PROVIDER, sa) orelse return null;
            access = b.key;
            account = b.account_id;
            if (nowS(app.io) + REFRESH_SKEW_S >= b.expires_at) {
                // refresh in place: the refresh token may or may not rotate; keep the old one if the response omits it.
                if (exchange(app, sa, "refresh_token", "", "", b.refresh_token)) |fresh| {
                    access = fresh.key;
                    const new_refresh = if (fresh.refresh_token.len > 0) fresh.refresh_token else b.refresh_token;
                    if (account.len == 0) account = fetchAccount(app, sa, access).id;
                    const base = workersAiBase(sa, account);
                    app.vault.putOAuth(uid, CF_PROVIDER, access, new_refresh, fresh.expires_at, account, base) catch {};
                    refresh_fail_s.store(0, .monotonic);
                } else {
                    refresh_fail_s.store(nowS(app.io), .monotonic);
                    // Refresh failed (rate blip / offline). Inside the skew window the token in hand is still
                    // LIVE: use it rather than failing a turn over a refresh that was merely early. Genuinely
                    // expired (revoked / offline): surface as not-connected so the caller falls back cleanly.
                    if (nowS(app.io) >= b.expires_at) return null;
                }
            }
        },
    }
    if (account.len == 0) return null;
    return finishToken(alloc, access, account);
}

fn finishToken(alloc: std.mem.Allocator, access: []const u8, account: []const u8) ?Token {
    if (account.len == 0) return null;
    return .{
        .key = alloc.dupe(u8, access) catch return null,
        .base_url = alloc.dupe(u8, workersAiBase(alloc, account)) catch return null,
        .account_id = alloc.dupe(u8, account) catch "",
    };
}

test "refreshPlan: a live token never waits, a failed refresh backs off, only an expired token waits" {
    const exp: i64 = 10_000;
    // far from expiry: use, whatever else is going on
    try std.testing.expectEqual(RefreshPlan.use, refreshPlan(exp - REFRESH_SKEW_S - 1, exp, 0, false));
    try std.testing.expectEqual(RefreshPlan.use, refreshPlan(exp - REFRESH_SKEW_S - 1, exp, 0, true));
    // due but live, nobody refreshing, no recent failure: refresh
    try std.testing.expectEqual(RefreshPlan.refresh, refreshPlan(exp - 60, exp, 0, false));
    // due but live, someone else refreshing: use the live token, do not queue
    try std.testing.expectEqual(RefreshPlan.use, refreshPlan(exp - 60, exp, 0, true));
    // due but live, the endpoint failed 10 s ago: use, do not pile on
    try std.testing.expectEqual(RefreshPlan.use, refreshPlan(exp - 60, exp, exp - 70, false));
    // the backoff has passed: refresh again
    try std.testing.expectEqual(RefreshPlan.refresh, refreshPlan(exp - 60, exp, exp - 60 - REFRESH_RETRY_S - 1, false));
    // expired: a refresh is mandatory - wait for the one in flight, else run it (a recent failure does not excuse it)
    try std.testing.expectEqual(RefreshPlan.wait, refreshPlan(exp + 1, exp, 0, true));
    try std.testing.expectEqual(RefreshPlan.refresh, refreshPlan(exp + 1, exp, exp - 5, false));
}

// ------------------------------------------------------------------------------------ live model list

/// The Workers AI catalog changes fast, so the model list is fetched LIVE from the user's account rather
/// than hardcoded. Cached in-process with a short TTL; the cache dies on restart, so every server start
/// refetches — "dynamic collection every time the machine turns on and connects". A FEW slots keyed by
/// uid, not one: the web app polls this for every signed-in user, and a single shared slot would make two
/// concurrent users evict each other every 15 minutes forever.
const MODELS_TTL_S: i64 = 900; // 15 min
const MC_SLOTS = 4;
const McSlot = struct { uid: u64 = 0, len: usize = 0, at: i64 = 0, buf: [16384]u8 = undefined };
var models_mtx: std.Io.Mutex = .init;
var mc: [MC_SLOTS]McSlot = @splat(.{});

/// Caller holds models_mtx. The slot for `uid`, or null.
fn mcFind(uid: u64) ?*McSlot {
    for (&mc) |*s| if (s.uid == uid and s.len > 0) return s;
    return null;
}

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
        result: []const struct {
            name: []const u8 = "",
            properties: ?[]const struct { property_id: []const u8 = "", value: []const u8 = "" } = null,
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(ModelsResp, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.result.len == 0) return null; // no models parsed → let the caller keep the catalog defaults
    // THE CONTEXT WINDOW RIDES ALONG. The catalog states it per model (properties[].context_window), and the
    // engine's compaction budget is sized from it: the id heuristic read "flash" as a small model and gave
    // deepseek-v4-flash a 32k window, against the catalog's 1,310,720 - so the working span was folded after
    // almost every step (67 compactions in one C1 run, 71% of its model time). See windowTokensFor.
    for (parsed.value.result) |m| {
        const props = m.properties orelse continue;
        for (props) |p| {
            if (std.mem.eql(u8, p.property_id, "context_window")) {
                const v = std.fmt.parseInt(u32, std.mem.trim(u8, p.value, " \t"), 10) catch continue;
                rememberWindow(app.io, m.name, v);
            } else if (std.mem.eql(u8, p.property_id, "reasoning")) {
                rememberProp(app.io, m.name, null, std.mem.eql(u8, std.mem.trim(u8, p.value, " \t"), "true"));
            }
        }
    }
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
// ------------------------------------------------------------------------------- catalog context windows
const WIN_SLOTS = 96;
/// One catalog entry the engine cares about: the window (0 = not stated) and whether the model reasons.
const WinSlot = struct { name: [120]u8 = undefined, len: usize = 0, tokens: u32 = 0, reasoning: bool = false };
var win_mtx: std.Io.Mutex = .init;
var wins: [WIN_SLOTS]WinSlot = @splat(.{});

/// Record what the catalog states for `name`; a null field leaves the slot's value alone.
fn rememberProp(io: std.Io, name: []const u8, tokens: ?u32, reasoning: ?bool) void {
    if (name.len == 0 or name.len > 120) return;
    win_mtx.lockUncancelable(io);
    defer win_mtx.unlock(io);
    var free: ?usize = null;
    for (&wins, 0..) |*w, i| {
        if (w.len == 0) {
            if (free == null) free = i;
            continue;
        }
        if (std.mem.eql(u8, w.name[0..w.len], name)) {
            if (tokens) |t| w.tokens = t;
            if (reasoning) |r| w.reasoning = r;
            return;
        }
    }
    const i = free orelse return; // table full: the models we did keep still answer
    @memcpy(wins[i].name[0..name.len], name);
    wins[i].len = name.len;
    wins[i].tokens = tokens orelse 0;
    wins[i].reasoning = reasoning orelse false;
}

fn rememberWindow(io: std.Io, name: []const u8, tokens: u32) void {
    if (tokens == 0) return;
    rememberProp(io, name, tokens, null);
}

fn windowFromTable(io: std.Io, model: []const u8) ?u32 {
    win_mtx.lockUncancelable(io);
    defer win_mtx.unlock(io);
    for (&wins) |*w| {
        if (w.len == model.len and std.mem.eql(u8, w.name[0..w.len], model)) return if (w.tokens == 0) null else w.tokens;
    }
    return null;
}

fn reasoningFromTable(io: std.Io, model: []const u8) ?bool {
    win_mtx.lockUncancelable(io);
    defer win_mtx.unlock(io);
    for (&wins) |*w| {
        if (w.len == model.len and std.mem.eql(u8, w.name[0..w.len], model)) return w.reasoning;
    }
    return null;
}

/// Whether the Workers AI catalog marks `model` as a reasoning model (its `reasoning` property), or null when
/// the catalog does not carry the model. Same table and same one-time fetch as windowTokensFor. The engine
/// doubles such a model's output cap: reasoning is spent from the same cap as the answer (ledger run H, turn
/// 23: 98 s of thought, cut at 8192 tokens, no answer).
pub fn reasoningFor(app: *App, uid: u64, model: []const u8) ?bool {
    if (!std.mem.startsWith(u8, model, "@cf/")) return null;
    if (reasoningFromTable(app.io, model)) |r| return r;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    _ = modelsJson(app, uid, arena.allocator());
    return reasoningFromTable(app.io, model);
}

/// The context window (tokens) the Workers AI catalog states for `model`, or null when the catalog does not
/// carry it. Reads the table filled by the last catalog fetch; on a miss it runs the (15-minute-cached) fetch
/// once, so the first turn of a session pays one small API call instead of a whole conversation of folding.
pub fn windowTokensFor(app: *App, uid: u64, model: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, model, "@cf/")) return null;
    if (windowFromTable(app.io, model)) |w| return w;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    _ = modelsJson(app, uid, arena.allocator());
    return windowFromTable(app.io, model);
}

test "windowTokensFor: the table remembers a model's window and answers only for it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // the table is process-global; use names no catalog will ever carry
    rememberWindow(io, "@cf/test/window-probe-a", 1_310_720);
    rememberWindow(io, "@cf/test/window-probe-b", 32_768);
    rememberWindow(io, "@cf/test/window-probe-a", 1_000_000); // an update replaces, never duplicates
    try std.testing.expectEqual(@as(?u32, 1_000_000), windowFromTable(io, "@cf/test/window-probe-a"));
    try std.testing.expectEqual(@as(?u32, 32_768), windowFromTable(io, "@cf/test/window-probe-b"));
    try std.testing.expect(windowFromTable(io, "@cf/test/window-probe-c") == null);
    try std.testing.expect(windowFromTable(io, "@cf/test/window-probe-") == null); // prefix is not a match
    // the reasoning flag rides the same slot, and a reasoning-only entry states no window
    rememberProp(io, "@cf/test/window-probe-a", null, true);
    try std.testing.expectEqual(@as(?bool, true), reasoningFromTable(io, "@cf/test/window-probe-a"));
    try std.testing.expectEqual(@as(?u32, 1_000_000), windowFromTable(io, "@cf/test/window-probe-a"));
    rememberProp(io, "@cf/test/window-probe-r", null, true);
    try std.testing.expectEqual(@as(?bool, true), reasoningFromTable(io, "@cf/test/window-probe-r"));
    try std.testing.expect(windowFromTable(io, "@cf/test/window-probe-r") == null);
    try std.testing.expect(reasoningFromTable(io, "@cf/test/window-probe-none") == null);
}

fn modelsJson(app: *App, uid: u64, alloc: std.mem.Allocator) ?[]const u8 {
    const now = nowS(app.io);
    {
        models_mtx.lockUncancelable(app.io);
        defer models_mtx.unlock(app.io);
        if (mcFind(uid)) |s| if (now - s.at < MODELS_TTL_S)
            return alloc.dupe(u8, s.buf[0..s.len]) catch null;
    }
    const fresh = fetchModelsList(app, uid, alloc) orelse {
        models_mtx.lockUncancelable(app.io);
        defer models_mtx.unlock(app.io);
        if (mcFind(uid)) |s| return alloc.dupe(u8, s.buf[0..s.len]) catch null;
        return null;
    };
    models_mtx.lockUncancelable(app.io);
    defer models_mtx.unlock(app.io);
    if (fresh.len <= mc[0].buf.len) {
        // reuse this uid's slot, else the oldest
        var slot: *McSlot = mcFind(uid) orelse blk: {
            var oldest = &mc[0];
            for (&mc) |*s| if (s.at < oldest.at) {
                oldest = s;
            };
            break :blk oldest;
        };
        @memcpy(slot.buf[0..fresh.len], fresh);
        slot.len = fresh.len;
        slot.uid = uid;
        slot.at = now;
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
    const account = fetchAccount(app, a, tok.key);
    if (account.id.len == 0) return page(res, false, "could not read your Cloudflare account (the token may lack account-settings.read)");
    const base = workersAiBase(a, account.id);
    app.vault.putOAuth(pend.uid, CF_PROVIDER, tok.key, tok.refresh_token, tok.expires_at, account.id, base) catch
        return page(res, false, "could not store the credential");
    // Presentation data beside the sealed credential: the account's display name plus the user's own
    // name/email (user:read — degrades to empties if the grant lacks it). Written before the R2 kick
    // so the first status poll after this redirect already carries the profile.
    const uinfo = fetchUserInfo(app, a, tok.key);
    writeProfile(app, pend.uid, .{ .account_id = account.id, .account_name = account.name, .email = uinfo.email, .user_name = uinfo.name });
    // Cook the R2 backup bucket in the background (bucket create if missing + first sync). Best-effort:
    // an account without the R2 subscription just records why in the r2 status, login still succeeds.
    cf_r2.kickSync(app, pend.uid);
    return page(res, true, if (account.name.len > 0) account.name else account.id);
}

/// GET /api/v1/oauth/cloudflare/status — clients poll this: is the feature configured, and is THIS user
/// connected (and as whom)? Carries the non-secret profile (account name, user name/email) so every
/// surface can say "signed in as …" from one call. Never returns the token. A status poll from a
/// connected user is also the heartbeat the R2 auto-backup rides (throttled inside cf_r2).
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
    var account_name: []const u8 = "";
    var email: []const u8 = "";
    var user_name: []const u8 = "";
    if (connected) {
        if (readProfile(app, u.id, a)) |p| {
            account_name = p.account_name;
            email = p.email;
            user_name = p.user_name;
        }
        cf_r2.maybeAutoSync(app, u.id);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    try out.print(app.gpa, "{{\"ok\":true,\"configured\":{},\"connected\":{},\"account_id\":\"{s}\",\"expires_at\":{d},\"account_name\":", .{ configured, connected, account, expires_at });
    try http.jstr(app.gpa, &out, account_name);
    try out.appendSlice(app.gpa, ",\"email\":");
    try http.jstr(app.gpa, &out, email);
    try out.appendSlice(app.gpa, ",\"user_name\":");
    try http.jstr(app.gpa, &out, user_name);
    try out.append(app.gpa, '}');
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, out.items);
}

/// POST /api/v1/oauth/cloudflare/logout — forget this user's stored Cloudflare credential and the
/// profile beside it. The R2 sync bookkeeping stays: the bucket is the USER'S (in their account), and
/// keeping the manifest means a later re-login resumes an incremental backup instead of re-uploading
/// everything.
pub fn logout(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    app.vault.del(u.id, CF_PROVIDER);
    deleteProfile(app, u.id);
    // Drop the cached model list too: within its TTL (and forever via the stale-fallback path) the
    // models route would otherwise keep answering connected:true with the departed account's list.
    {
        models_mtx.lockUncancelable(app.io);
        defer models_mtx.unlock(app.io);
        for (&mc) |*s| if (s.uid == u.id) {
            s.* = .{};
        };
    }
    try res.json(.{ .ok = true, .disconnected = true }, .{});
}

/// HTML-escape `s` into an alloc-owned copy. The callback page splices two UNTRUSTED strings into its
/// markup — the raw `error` query param (the route is public: any crafted link reaches it, no session
/// needed) and the Cloudflare account display name (arbitrary text an account admin sets) — and this
/// page executes on the same origin the authenticated web client calls its APIs from. Unescaped, either
/// is a reflected XSS running with the victim's session cookie on every same-origin fetch.
fn htmlEsc(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => out.appendSlice(alloc, "&amp;") catch return "",
        '<' => out.appendSlice(alloc, "&lt;") catch return "",
        '>' => out.appendSlice(alloc, "&gt;") catch return "",
        '"' => out.appendSlice(alloc, "&quot;") catch return "",
        '\'' => out.appendSlice(alloc, "&#39;") catch return "",
        else => out.append(alloc, c) catch return "",
    };
    return out.items;
}

/// Render the post-callback browser page (the only HTML this module returns). The tab may have been
/// opened by the WEB app (window.open) or the DESK (system browser): the script pokes an opener if one
/// exists so the web app can react instantly, and both clients' status polls remain the source of truth.
fn page(res: *httpz.Response, ok: bool, detail: []const u8) !void {
    res.content_type = .HTML;
    res.status = if (ok) 200 else 400;
    const title = if (ok) "Connected to Cloudflare" else "Cloudflare login failed";
    const msg = if (ok) "You're connected. You can close this tab and return to the veil." else "Something went wrong.";
    res.body = try std.fmt.allocPrint(res.arena,
        \\<!doctype html><meta charset="utf-8"><title>{s}</title>
        \\<div style="font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:16vh auto;padding:0 1rem;color:#1a1b26">
        \\<h2 style="color:{s}">{s}</h2><p>{s}</p><p style="color:#565f89;font-size:14px">{s}</p></div>
        \\<script>try{{if(window.opener)window.opener.postMessage('nl-cf-oauth','*');}}catch(e){{}}
        \\if({s})setTimeout(function(){{try{{window.close();}}catch(e){{}}}},1500);</script>
    , .{ title, if (ok) "#2ac3de" else "#f7768e", title, msg, htmlEsc(res.arena, detail), if (ok) "true" else "false" });
}

test "pkce challenge is base64url sha256 of the verifier" {
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"; // RFC 7636 example verifier
    var chal: [43]u8 = undefined;
    pkceChallenge(verifier, &chal);
    // RFC 7636 appendix B expected challenge
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &chal);
}

test "htmlEsc neutralizes every markup-significant byte (the callback page's XSS gate)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("&lt;script&gt;x&lt;/script&gt;", htmlEsc(a, "<script>x</script>"));
    try std.testing.expectEqualStrings("a &amp; b &quot;c&quot; &#39;d&#39;", htmlEsc(a, "a & b \"c\" 'd'"));
    try std.testing.expectEqualStrings("plain-account-name", htmlEsc(a, "plain-account-name"));
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
