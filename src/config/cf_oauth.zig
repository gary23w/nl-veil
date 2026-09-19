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
const builtin = @import("builtin");
const bu = @import("../worker/browser/util.zig"); // sleepMs: a raw-thread sleep, no Io park
const llm = @import("../worker/llm.zig"); // runCurl, KEY_CFG_MAX + the curl-config escaping: a call's secrets ride curl's stdin
const fakehttp = @import("../worker/fakehttp.zig"); // TEST ONLY: the stand-in the transport tests dial
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

/// One call from this server's own Cloudflare code, through `curl`. pub, with the content type as a parameter,
/// because cf_r2 reuses it for bucket/object calls (JSON and raw octet-stream bodies) and cf_tunnel for its v4
/// calls, rather than growing a second curl wrapper with its own secret-handling mistakes.
pub fn apiCall(app: *App, method: []const u8, url: []const u8, body: []const u8, bearer: []const u8, content_type: []const u8) ?[]u8 {
    return curl(appCurl(app), method, url, body, bearer, content_type);
}

/// The token/consent legs all speak forms; keep their call sites one argument shorter.
fn curlCall(app: *App, method: []const u8, url: []const u8, form_body: []const u8, bearer: []const u8) ?[]u8 {
    return curl(appCurl(app), method, url, form_body, bearer, "application/x-www-form-urlencoded");
}

/// The server's own calls: a body that rides a file goes in the data dir, and a call gets 30 s and a 1 MiB answer.
fn appCurl(app: *App) CurlOpts {
    return .{ .gpa = app.gpa, .io = app.io, .scratch = app.data, .body_prefix = ".cfoauth-body-", .max_time_s = 30, .stdout_limit = 1 << 20 };
}

/// How one Cloudflare call runs (`curl`). Each caller brings its own: this file and `apiCall` (appCurl), and the cf_
/// tool belt (cftools.call: the run dir, 120 s, 8 MiB).
pub const CurlOpts = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Where a body curl's config cannot carry is written while its call runs: `{scratch}/{body_prefix}{16 hex}`.
    scratch: []const u8,
    body_prefix: []const u8,
    max_time_s: u32,
    stdout_limit: usize,
    /// More argv, for what may sit on the process table: never a secret (cftools' multipart -F parts).
    extra: []const []const u8 = &.{},
};

/// One outbound HTTPS call to Cloudflare through curl. This file's token legs, `apiCall` (cf_r2, cf_tunnel) and the
/// cf_ tool belt (cftools.call) all send theirs here, so the secret handling exists once. Returns the response body
/// (gpa-owned), or null: curl could not run or answered nothing, or the call was refused before it started (below).
///
/// THE BEARER NEVER TOUCHES DISK. It rides the config curl reads from its stdin (`-K -`, llm.runCurl): never the argv,
/// and no file, not even while curl runs. It used to ride a config FILE for the call's whole life, up to 120 s:
/// `{data}/.cfoauth-cfg-*`, and a run dir's `.cfapi-cfg-*`, inside a data dir that is often a synced folder. A sync
/// client could upload one mid-call, deleting a synced file only sends the cloud copy to the recycle bin, and a
/// process killed mid-call left it where it was.
///
/// A BODY RIDES THE SAME CONFIG (cfgData) whenever curl reads it back byte for byte and the whole config still fits
/// the pipe (llm.KEY_CFG_MAX). The token exchange's form, which carries the refresh token, or the code and its
/// verifier, always does: it used to sit in `{data}/.cfoauth-body-*` for the call's life. Only a body too big for the
/// pipe, or holding NUL or 0x1A, goes to a file, `{scratch}/{body_prefix}{16 hex}`, the call's own and deleted when it
/// returns: an upload (cf_r2's objects, cf_r2_put's bytes, a large cf_api payload), never the bearer. A bearer or
/// content type the config cannot carry (llm.cfgHeader), or a bearer too long for the pipe, fails the call before a file
/// is written or a connection made: a secret never falls back to a file.
pub fn curl(o: CurlOpts, method: []const u8, url: []const u8, body: []const u8, bearer: []const u8, content_type: []const u8) ?[]u8 {
    const gpa = o.gpa;
    const io = o.io;
    var cfg: std.ArrayListUnmanaged(u8) = .empty;
    defer cfg.deinit(gpa);
    if (bearer.len > 0 and !(llm.cfgHeader(gpa, &cfg, "Authorization: Bearer ", bearer) catch return null)) return null;
    if (body.len > 0 and content_type.len > 0 and !(llm.cfgHeader(gpa, &cfg, "Content-Type: ", content_type) catch return null)) return null;
    if (cfg.items.len > llm.KEY_CFG_MAX) return null; // runCurl's precondition: the pipe holds the config whole
    const in_file = body.len > 0 and !(cfgData(gpa, &cfg, body) catch return null);

    var sfx: [8]u8 = undefined;
    io.random(&sfx);
    const tag = std.fmt.bytesToHex(sfx, .lower);
    var body_path_buf: [700]u8 = undefined;
    const body_path = std.fmt.bufPrint(&body_path_buf, "{s}/{s}{s}", .{ o.scratch, o.body_prefix, tag }) catch return null;
    var data_at_buf: [710]u8 = undefined;
    const data_at = std.fmt.bufPrint(&data_at_buf, "@{s}", .{body_path}) catch return null;
    // Armed before the write, so a half-written body goes too. It runs once curl has exited: runCurl waits for it.
    defer if (in_file) std.Io.Dir.cwd().deleteFile(io, body_path) catch {};
    if (in_file) std.Io.Dir.cwd().writeFile(io, .{ .sub_path = body_path, .data = body }) catch return null;

    var max_time_buf: [12]u8 = undefined;
    const max_time = std.fmt.bufPrint(&max_time_buf, "{d}", .{o.max_time_s}) catch return null;
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sS", "--max-time", max_time, "-X", method, "-K", "-" }) catch return null;
    if (in_file) av.appendSlice(gpa, &.{ "--data-binary", data_at }) catch return null;
    av.appendSlice(gpa, o.extra) catch return null;
    av.append(gpa, url) catch return null;

    if (builtin.is_test) if (test_before_curl) |hold| hold();
    const run = llm.runCurl(gpa, io, av.items, cfg.items, o.stdout_limit) catch return null;
    gpa.free(run.stderr);
    if (run.stdout.len == 0) {
        gpa.free(run.stdout);
        return null;
    }
    return run.stdout;
}

/// TEST SEAM: runs on the calling thread once a Cloudflare call has written everything it writes, just before its curl
/// starts (`curl`): the moment a config file would already be on disk. pub: cftools' tests hold the belt's calls here.
pub var test_before_curl: if (builtin.is_test) ?*const fn () void else void = if (builtin.is_test) null else {};

/// Append `data-raw = "<body>"` to a curl config when curl reads `body` back byte for byte and the whole config still
/// fits the pipe (llm.KEY_CFG_MAX). False, with the config as it was, otherwise: the call sends the body from a file.
/// `data-raw`, NOT `data-binary`: data-binary reads a value that starts with @ as a file name, and curl 8.5, 8.17 and
/// 8.21 each uploaded that file's contents instead of the body (measured 2026-09-17).
fn cfgData(gpa: std.mem.Allocator, cfg: *std.ArrayListUnmanaged(u8), body: []const u8) error{OutOfMemory}!bool {
    if (body.len > llm.KEY_CFG_MAX) return false; // escaping only lengthens it
    for (body) |c| if (c == 0 or c == 0x1A) return false; // no escape carries either (llm.cfgEscape)
    const mark = cfg.items.len;
    try cfg.appendSlice(gpa, "data-raw = \"");
    try llm.cfgEscape(gpa, cfg, body);
    try cfg.appendSlice(gpa, "\"\n");
    if (cfg.items.len <= llm.KEY_CFG_MAX) return true;
    cfg.shrinkRetainingCapacity(mark);
    return false;
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
/// The catalog's shape, as much of it as the engine reads. `value` is whatever the catalog puts there - a
/// string for context_window and reasoning, a LIST for price - so it is read as a JSON value: typing it as
/// a string failed the whole parse for every paid model, and with it the windows, the reasoning flags and
/// the model list itself (found 2026-09-03: a GLM conversation folding 6 KB at a time).
const CatalogResp = struct {
    result: []const struct {
        name: []const u8 = "",
        properties: ?[]const struct { property_id: []const u8 = "", value: std.json.Value = .null } = null,
    } = &.{},
};

test "the catalog parse survives a list-valued property and reads the window and the reasoning flag" {
    const sample =
        \\{"result":[{"name":"@cf/zai-org/glm-5.3-flash","properties":[{"property_id":"context_window","value":"1310720"},
        \\{"property_id":"reasoning","value":"true"},{"property_id":"price","value":[{"unit":"per M input tokens","price":0.44,"currency":"USD"}]}]},
        \\{"name":"@cf/meta/llama-3.3-70b","properties":[{"property_id":"context_window","value":131072},{"property_id":"reasoning","value":false}]},
        \\{"name":"@cf/x/no-props"}],"success":true,"errors":[],"result_info":{"count":3}}
    ;
    const parsed = try std.json.parseFromSlice(CatalogResp, std.testing.allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.result.len);
    var win: ?u32 = null;
    var reasons: ?bool = null;
    for (parsed.value.result[0].properties.?) |p| {
        if (std.mem.eql(u8, p.property_id, "context_window")) win = switch (p.value) {
            .string => |x| std.fmt.parseInt(u32, x, 10) catch null,
            .integer => |n| @intCast(n),
            else => null,
        };
        if (std.mem.eql(u8, p.property_id, "reasoning")) reasons = switch (p.value) {
            .string => |x| std.mem.eql(u8, x, "true"),
            .bool => |b| b,
            else => null,
        };
    }
    try std.testing.expectEqual(@as(?u32, 1_310_720), win);
    try std.testing.expectEqual(@as(?bool, true), reasons);
    // the second model states its window as a number and its flag as a bool
    for (parsed.value.result[1].properties.?) |p| {
        if (std.mem.eql(u8, p.property_id, "context_window")) try std.testing.expectEqual(@as(i64, 131072), p.value.integer);
        if (std.mem.eql(u8, p.property_id, "reasoning")) try std.testing.expect(!p.value.bool);
    }
    try std.testing.expect(parsed.value.result[2].properties == null);
}

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
    const parsed = std.json.parseFromSlice(CatalogResp, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
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
                const v: u32 = switch (p.value) {
                    .string => |x| std.fmt.parseInt(u32, std.mem.trim(u8, x, " \t"), 10) catch continue,
                    .integer => |n| if (n > 0 and n <= std.math.maxInt(u32)) @intCast(n) else continue,
                    else => continue,
                };
                rememberWindow(app.io, m.name, v);
            } else if (std.mem.eql(u8, p.property_id, "reasoning")) {
                const r: bool = switch (p.value) {
                    .string => |x| std.mem.eql(u8, std.mem.trim(u8, x, " \t"), "true"),
                    .bool => |b| b,
                    else => continue,
                };
                rememberProp(app.io, m.name, null, r);
            }
        }
    }
    wins_filled_at = nowSeconds(app.io);
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

/// When the table was last filled from the catalog (unix seconds; 0 = never). A miss refreshes the catalog
/// at most once per MODELS_TTL_S: the names cache alone (modelsJson) does not fill the table, so a warm
/// cache used to leave every window unknown until it expired.
var wins_filled_at: i128 = 0;

fn nowSeconds(io: std.Io) i128 {
    return @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
}

fn ensureCatalog(app: *App, uid: u64) void {
    const now = nowSeconds(app.io);
    if (wins_filled_at != 0 and now - wins_filled_at < MODELS_TTL_S) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    _ = fetchModelsList(app, uid, arena.allocator());
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
    ensureCatalog(app, uid);
    return reasoningFromTable(app.io, model);
}

/// The context window (tokens) the Workers AI catalog states for `model`, or null when the catalog does not
/// carry it. Reads the table filled by the last catalog fetch; on a miss it runs the (15-minute-cached) fetch
/// once, so the first turn of a session pays one small API call instead of a whole conversation of folding.
pub fn windowTokensFor(app: *App, uid: u64, model: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, model, "@cf/")) return null;
    if (windowFromTable(app.io, model)) |w| return w;
    ensureCatalog(app, uid);
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
    , .{ title, if (ok) "#f6821f" else "#f7768e", title, msg, htmlEsc(res.arena, detail), if (ok) "true" else "false" });
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

// ---------------------------------------------------------------------------
// No Cloudflare secret touches disk (`curl`). These drive the REAL curl against a loopback stand-in and look through
// every file under the call's scratch dir while the call is in flight (ScratchWatch): at test_before_curl, with all the
// call writes on disk and its curl about to start, and from the stand-in, with curl connected and waiting on the
// reply. Then once more after the call has returned.
// ---------------------------------------------------------------------------

/// Never real credentials; distinctive, so a byte search for each is exact.
const TEST_BEARER = "cfat-test-bearer-3d1f-not-a-real-token";
const TEST_REFRESH = "cfrt-test-refresh-9a2e-not-a-real-token";
const TEST_CODE = "cfac-test-code-51b7-not-a-real-code";
const TEST_VERIFIER = "cfpv-test-verifier-c84d-not-a-real-verifier";
/// What the stand-in token endpoint answers with: the tokens a real exchange brings back.
const TEST_FRESH_ACCESS = "cfat-test-fresh-access-6e0b-not-a-real-token";
const TEST_FRESH_REFRESH = "cfrt-test-fresh-refresh-2c5a-not-a-real-token";

/// TEST ONLY. Looks through every file under one dir for secrets while Cloudflare calls are in flight: at
/// test_before_curl (`atSeam`) and at the stand-in (`onWire`, for fakehttp.Server.startWatched). It counts each kind of
/// look and the most files named like a call's body (`body_prefix`) one look found, and keeps the first file a look
/// could not clear: one holding a secret, or one it could not read. pub: cftools' tests watch the belt's calls with it.
pub const ScratchWatch = struct {
    var io_: std.Io = undefined;
    var dir: []const u8 = "";
    var body_prefix: []const u8 = "";
    var secrets: []const []const u8 = &.{};
    var at_seam: std.atomic.Value(u32) = .init(0);
    var on_wire: std.atomic.Value(u32) = .init(0);
    var bodies: std.atomic.Value(u32) = .init(0);
    var found: std.atomic.Value(u32) = .init(0);
    var found_name: [256]u8 = undefined;
    var found_len: usize = 0;

    pub fn arm(io: std.Io, dir_path: []const u8, prefix: []const u8, watched: []const []const u8) void {
        io_ = io;
        dir = dir_path;
        body_prefix = prefix;
        secrets = watched;
        at_seam.store(0, .monotonic);
        on_wire.store(0, .monotonic);
        bodies.store(0, .monotonic);
        found.store(0, .monotonic);
        found_len = 0;
        test_before_curl = atSeam;
    }
    pub fn disarm() void {
        test_before_curl = null;
    }
    fn atSeam() void {
        _ = at_seam.fetchAdd(1, .monotonic);
        keepMost(look());
    }
    /// The stand-in's hook.
    pub fn onWire() void {
        _ = on_wire.fetchAdd(1, .monotonic);
        keepMost(look());
    }
    fn keepMost(n: u32) void {
        var cur = bodies.load(.monotonic);
        while (n > cur) cur = bodies.cmpxchgWeak(cur, n, .monotonic, .monotonic) orelse break;
    }
    /// One pass over the dir: notes what it cannot clear, and returns how many body files it saw.
    fn look() u32 {
        const gpa = std.testing.allocator;
        var d = std.Io.Dir.cwd().openDir(io_, dir, .{ .iterate = true }) catch {
            note("<the dir would not open>");
            return 0;
        };
        defer d.close(io_);
        var walker = d.walk(gpa) catch {
            note("<the dir would not walk>");
            return 0;
        };
        defer walker.deinit();
        var n: u32 = 0;
        while (true) {
            const next = walker.next(io_) catch {
                note("<the dir would not list>");
                return n;
            };
            const ent = next orelse break;
            if (ent.kind != .file) continue;
            if (std.mem.startsWith(u8, ent.basename, body_prefix)) n += 1;
            const data = ent.dir.readFileAlloc(io_, ent.basename, gpa, .limited(64 << 20)) catch {
                note(ent.path); // a file the look cannot read is one it cannot clear
                continue;
            };
            defer gpa.free(data);
            for (secrets) |s| {
                if (std.mem.indexOf(u8, data, s) != null) note(ent.path);
            }
        }
        return n;
    }
    fn note(name: []const u8) void {
        if (found.fetchAdd(1, .monotonic) > 0) return;
        found_len = @min(name.len, found_name.len);
        @memcpy(found_name[0..found_len], name[0..found_len]);
    }
    /// Fails if a look found a secret on disk (or could not rule one out), if the looks were not exactly `seam` at the
    /// seam and `wire` on the wire (one each per call that reached curl and the stand-in), or if the most body files a
    /// look saw was not `want_bodies`. Read only once the stand-in has stopped: its serve thread looks too.
    pub fn expect(seam: u32, wire: u32, want_bodies: u32) !void {
        if (found.load(.monotonic) > 0) {
            std.debug.print("\na secret was on disk while its call ran: {s}/{s}\n", .{ dir, found_name[0..found_len] });
            return error.SecretOnDiskMidCall;
        }
        if (at_seam.load(.monotonic) != seam or on_wire.load(.monotonic) != wire) {
            std.debug.print("\nthe mid-call looks ran {d} at the seam (want {d}), {d} on the wire (want {d})\n", .{ at_seam.load(.monotonic), seam, on_wire.load(.monotonic), wire });
            return error.MidCallLooks;
        }
        if (bodies.load(.monotonic) != want_bodies) {
            std.debug.print("\na look mid-call saw {d} body file(s), want {d}\n", .{ bodies.load(.monotonic), want_bodies });
            return error.BodyFiles;
        }
    }
    /// One more look once the call has returned: fails on a secret as `expect` does, and returns the body files left.
    pub fn leftAfter() !u32 {
        const n = look();
        if (found.load(.monotonic) > 0) {
            std.debug.print("\na secret is on disk after its call: {s}/{s}\n", .{ dir, found_name[0..found_len] });
            return error.SecretOnDiskAfterCall;
        }
        return n;
    }
    /// Whether curl runs on this machine. Without it no call dials, so a test that needs the wire skips.
    pub fn curlRuns(gpa: std.mem.Allocator, io: std.Io) bool {
        const r = std.process.run(gpa, io, .{ .argv = &.{ "curl", "--version" }, .stdout_limit = .limited(16 << 10) }) catch return false;
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        return r.term == .exited and r.term.exited == 0;
    }
};

/// TEST ONLY. The head and the body of the request a stand-in captured. fakehttp keeps each head line without its
/// "\n", so the head ends at the first "\r\r".
fn splitRequest(req: []const u8) struct { head: []const u8, body: []const u8 } {
    const end = std.mem.indexOf(u8, req, "\r\r") orelse return .{ .head = req, .body = "" };
    return .{ .head = req[0..end], .body = req[end + 2 ..] };
}

test "a body rides curl's stdin config byte for byte, and no body can add a header or a URL to the call" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    if (!ScratchWatch.curlRuns(gpa, io)) return error.SkipZigTest;
    const root = "zig-cfoauth-cfgbody-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    // What `data-binary` would upload in place of a body that starts with @ and names this file.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/decoy.txt", .data = "DECOY-FILE-CONTENTS" });
    // Every byte curl's config can carry, once each: all but NUL and 0x1A.
    var every: [254]u8 = undefined;
    var n: usize = 0;
    for (1..256) |b| {
        if (b == 0x1A) continue;
        every[n] = @intCast(b);
        n += 1;
    }

    const Case = enum { injection, at_file, every_byte, token_form };
    for ([_]Case{ .injection, .at_file, .every_byte, .token_form }) |c| {
        var srv: fakehttp.Server = undefined;
        try srv.startWatched(io, &.{}, fakehttp.wire("{\"success\":true}"), ScratchWatch.onWire);
        var running = true;
        defer if (running) srv.stop();
        ScratchWatch.arm(io, root, ".cftest-body-", &.{ TEST_BEARER, TEST_REFRESH });
        defer ScratchWatch.disarm();
        const body = switch (c) {
            // Unescaped, the line feeds would end the value: curl would send an extra header and dial a second URL, on
            // this same stand-in, carrying the bearer there too.
            .injection => try std.fmt.allocPrint(gpa, "x\"\nheader = \"X-Injected: yes\"\nurl = \"http://127.0.0.1:{d}/injected\"\n#", .{srv.port}),
            .at_file => try gpa.dupe(u8, "@" ++ root ++ "/decoy.txt"),
            .every_byte => try gpa.dupe(u8, &every),
            .token_form => try gpa.dupe(u8, "grant_type=refresh_token&client_id=test-client&refresh_token=" ++ TEST_REFRESH),
        };
        defer gpa.free(body);
        var ub: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/client/v4/call", .{srv.port});
        const r = curl(.{ .gpa = gpa, .io = io, .scratch = root, .body_prefix = ".cftest-body-", .max_time_s = 30, .stdout_limit = 1 << 20 }, "POST", url, body, TEST_BEARER, "application/x-www-form-urlencoded");
        defer if (r) |x| gpa.free(x);
        srv.stop(); // joins the serve thread: request(), the call log and the watch are only safe to read after it
        running = false;

        try std.testing.expect(r != null);
        // One request, to the URL on the argv, with one extra header: the bearer...
        if (srv.call_count != 1 or srv.countCalls("POST", "/injected") != 0) {
            std.debug.print("\n[{t}] the body added a request: {d} calls\n", .{ c, srv.call_count });
            return error.BodyAddedARequest;
        }
        const sent = splitRequest(srv.request());
        try std.testing.expect(std.mem.indexOf(u8, sent.head, "Authorization: Bearer " ++ TEST_BEARER) != null);
        if (std.mem.indexOf(u8, sent.head, "X-Injected") != null) {
            std.debug.print("\n[{t}] the body added a header\n", .{c});
            return error.BodyAddedAHeader;
        }
        // ...and the body as it was meant, byte for byte: a leading @ is two bytes of body, not the file they name.
        if (!std.mem.eql(u8, body, sent.body)) {
            std.debug.print("\n[{t}] the body arrived changed: {d} bytes, wanted {d}: {s}\n", .{ c, sent.body.len, body.len, sent.body[0..@min(sent.body.len, 64)] });
            return error.BodyChanged;
        }
        // It rode the config: no body file at the seam or on the wire, and no file held the bearer or the refresh token.
        try ScratchWatch.expect(1, 1, 0);
        try std.testing.expectEqual(@as(u32, 0), try ScratchWatch.leftAfter());
    }
}

test "a body curl's config cannot carry goes whole from a file that never holds the bearer and leaves with its call" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    if (!ScratchWatch.curlRuns(gpa, io)) return error.SkipZigTest;
    const root = "zig-cfoauth-filebody-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    const Case = enum { escapes_past_the_pipe, past_the_pipe, nul, ctrl_z };
    for ([_]Case{ .escapes_past_the_pipe, .past_the_pipe, .nul, .ctrl_z }) |c| {
        const body = switch (c) {
            // short enough raw, but every byte doubles when escaped, so the config would pass KEY_CFG_MAX
            .escapes_past_the_pipe => blk: {
                const b = try gpa.alloc(u8, llm.KEY_CFG_MAX / 2 + 16);
                @memset(b, '"');
                break :blk b;
            },
            .past_the_pipe => blk: {
                const b = try gpa.alloc(u8, 16 << 10);
                for (b, 0..) |*x, i| x.* = @truncate(i *% 31);
                break :blk b;
            },
            .nul => try gpa.dupe(u8, "an object\x00with a NUL in it"),
            .ctrl_z => try gpa.dupe(u8, "an object\x1awith 0x1A in it"),
        };
        defer gpa.free(body);
        var srv: fakehttp.Server = undefined;
        try srv.startWatched(io, &.{}, fakehttp.wire("{\"success\":true}"), ScratchWatch.onWire);
        var running = true;
        defer if (running) srv.stop();
        ScratchWatch.arm(io, root, ".cftest-body-", &.{TEST_BEARER});
        defer ScratchWatch.disarm();
        var ub: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/client/v4/objects/k", .{srv.port});
        const r = curl(.{ .gpa = gpa, .io = io, .scratch = root, .body_prefix = ".cftest-body-", .max_time_s = 30, .stdout_limit = 1 << 20 }, "PUT", url, body, TEST_BEARER, "application/octet-stream");
        defer if (r) |x| gpa.free(x);
        srv.stop();
        running = false;

        try std.testing.expect(r != null);
        const sent = splitRequest(srv.request());
        try std.testing.expect(std.mem.indexOf(u8, sent.head, "Authorization: Bearer " ++ TEST_BEARER) != null);
        if (!std.mem.eql(u8, body, sent.body)) {
            std.debug.print("\n[{t}] the body arrived changed: {d} bytes, wanted {d}\n", .{ c, sent.body.len, body.len });
            return error.BodyChanged;
        }
        // The body was on disk while curl ran, in a file of its own that held no bearer, and it is gone now.
        try ScratchWatch.expect(1, 1, 1);
        try std.testing.expectEqual(@as(u32, 0), try ScratchWatch.leftAfter());
    }
}

test "a header value curl's config cannot carry fails the call before curl starts, and leaves nothing on disk" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfoauth-refused-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    const long_bearer = try gpa.alloc(u8, llm.KEY_CFG_MAX); // with its header around it, the config passes the pipe
    defer gpa.free(long_bearer);
    @memset(long_bearer, 'k');
    const Case = struct { what: []const u8, bearer: []const u8, content_type: []const u8 };
    const cases = [_]Case{
        .{ .what = "a line break in the bearer", .bearer = TEST_BEARER ++ "\nurl = \"http://127.0.0.1:9/elsewhere\"", .content_type = "application/json" },
        .{ .what = "DEL in the bearer", .bearer = TEST_BEARER ++ "\x7f", .content_type = "application/json" },
        .{ .what = "a bearer too long for the pipe", .bearer = long_bearer, .content_type = "application/json" },
        .{ .what = "a line break in the content type", .bearer = TEST_BEARER, .content_type = "application/json\r\nX-Injected: yes" },
    };
    for (cases) |c| {
        var srv: fakehttp.Server = undefined;
        try srv.startWatched(io, &.{}, fakehttp.wire("{\"success\":true}"), ScratchWatch.onWire);
        var running = true;
        defer if (running) srv.stop();
        ScratchWatch.arm(io, root, ".cftest-body-", &.{TEST_BEARER});
        defer ScratchWatch.disarm();
        var ub: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/client/v4/call", .{srv.port});
        // a body past the pipe too: the call would write it to a file, if it got that far
        const body = try gpa.alloc(u8, 16 << 10);
        defer gpa.free(body);
        @memset(body, 'b');
        const r = curl(.{ .gpa = gpa, .io = io, .scratch = root, .body_prefix = ".cftest-body-", .max_time_s = 30, .stdout_limit = 1 << 20 }, "POST", url, body, c.bearer, c.content_type);
        defer if (r) |x| gpa.free(x);
        srv.stop();
        running = false;

        if (r != null or srv.conns.load(.monotonic) != 0) {
            std.debug.print("\n[{s}] the call went ahead: answer={} connections={d}\n", .{ c.what, r != null, srv.conns.load(.monotonic) });
            return error.CallNotRefused;
        }
        try ScratchWatch.expect(0, 0, 0); // it never reached the point where its curl starts
        try std.testing.expectEqual(@as(u32, 0), try ScratchWatch.leftAfter());
    }
}

test "a token exchange and a bearer call keep every secret off disk: the refresh token, the code and its verifier, the tokens that come back, and the bearer" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfoauth-exchange-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!ScratchWatch.curlRuns(gpa, io)) return error.SkipZigTest;
    ta.app.cf_oauth_client_id = "test-client";
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = fakehttp.wire("{\"access_token\":\"" ++ TEST_FRESH_ACCESS ++ "\",\"refresh_token\":\"" ++ TEST_FRESH_REFRESH ++ "\",\"expires_in\":3600,\"token_type\":\"bearer\"}");
    const accounts = fakehttp.wire("{\"success\":true,\"result\":[{\"id\":\"acct-7\",\"name\":\"Test Account\"}]}");
    const Leg = enum { refresh, code, account };
    for ([_]Leg{ .refresh, .code, .account }) |leg| {
        var srv: fakehttp.Server = undefined;
        try srv.startWatched(io, &.{}, if (leg == .account) accounts else tokens, ScratchWatch.onWire);
        var running = true;
        defer if (running) srv.stop();
        // The whole data dir, since that is where these calls' scratch goes.
        ScratchWatch.arm(io, root, ".cfoauth-body-", &.{ TEST_BEARER, TEST_REFRESH, TEST_CODE, TEST_VERIFIER, TEST_FRESH_ACCESS, TEST_FRESH_REFRESH });
        defer ScratchWatch.disarm();
        var tb: [80]u8 = undefined;
        ta.app.cf_oauth_token_url = try std.fmt.bufPrint(&tb, "http://127.0.0.1:{d}/oauth2/token", .{srv.port});
        var ab: [80]u8 = undefined;
        ta.app.cf_oauth_accounts_url = try std.fmt.bufPrint(&ab, "http://127.0.0.1:{d}/client/v4/accounts", .{srv.port});
        switch (leg) {
            .refresh => {
                const b = exchange(&ta.app, a, "refresh_token", "", "", TEST_REFRESH) orelse return error.ExchangeFailed;
                try std.testing.expectEqualStrings(TEST_FRESH_ACCESS, b.key);
                try std.testing.expectEqualStrings(TEST_FRESH_REFRESH, b.refresh_token);
            },
            .code => {
                const b = exchange(&ta.app, a, "authorization_code", TEST_CODE, TEST_VERIFIER, "") orelse return error.ExchangeFailed;
                try std.testing.expectEqualStrings(TEST_FRESH_ACCESS, b.key);
            },
            .account => try std.testing.expectEqualStrings("acct-7", fetchAccount(&ta.app, a, TEST_BEARER).id),
        }
        srv.stop();
        running = false;

        // Each leg's secret reached the wire: the form in the body, the bearer in the head. A secret that never got to
        // curl would pass every disk check below and fail every real login.
        const sent = splitRequest(srv.request());
        const Seen = struct { in: []const u8, want: []const u8 };
        const seen: Seen = switch (leg) {
            .refresh => .{ .in = sent.body, .want = "grant_type=refresh_token&client_id=test-client&refresh_token=" ++ TEST_REFRESH },
            .code => .{ .in = sent.body, .want = "code=" ++ TEST_CODE ++ "&code_verifier=" ++ TEST_VERIFIER },
            .account => .{ .in = sent.head, .want = "Authorization: Bearer " ++ TEST_BEARER },
        };
        if (std.mem.indexOf(u8, seen.in, seen.want) == null) {
            std.debug.print("\n[{t}] the stand-in never saw {s}: {s}\n", .{ leg, seen.want, srv.request() });
            return error.SecretNeverSent;
        }
        try ScratchWatch.expect(1, 1, 0);
        try std.testing.expectEqual(@as(u32, 0), try ScratchWatch.leftAfter());
    }
}
