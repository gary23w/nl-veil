//! HTTP layer shared context — the `App` wiring struct plus the auth / JSON / error helpers every handler uses.

const std = @import("std");
const httpz = @import("httpz");
const auth_core = @import("../auth/auth_core.zig");

pub const Auth = auth_core.Auth;
pub const User = auth_core.User;
pub const Supervisor = @import("../worker/control/supervisor.zig").Supervisor;
pub const AuditLog = @import("../obs/audit_log.zig").AuditLog;
pub const LoginGuard = @import("../auth/login_guard.zig").LoginGuard;
pub const KeyVault = @import("../config/key_vault.zig").KeyVault;
pub const NeuronLedger = @import("../plan/neurons.zig").NeuronLedger;
pub const ApiKeys = @import("../auth/api_keys.zig").ApiKeys;

pub const COOKIE = "nl_sess";

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    auth: *Auth,
    sup: *Supervisor,
    audit: *AuditLog,
    login_guard: *LoginGuard,
    vault: *KeyVault,
    data: []const u8,
    server_key: [32]u8,
    open_registration: bool = false,
    cf_account_id: []const u8 = "",
    workers_ai_token: []const u8 = "",
    retention_days: u32 = 14,
    production: bool = false,
    // SERVER-SET DEFAULT MODEL. The host configures one model + endpoint (NL_DEFAULT_MODEL /
    // NL_DEFAULT_BASE_URL) that web users fall back to, so somebody who knows nothing about models can
    // just start typing. A user's own choice always wins; this only fills a BLANK. The key is never part
    // of it — that resolves server-side from the user's vault, so a default can never leak a credential
    // to a browser.
    default_model: []const u8 = "",
    default_base_url: []const u8 = "",
    ledger: ?*NeuronLedger = null,
    keys: ?*ApiKeys = null,
    // Cloudflare OAuth (self-managed public client). Enabled only when cf_oauth_client_id is non-empty; all
    // fields are overridable from the environment in main() so a deployment registers its own client without a
    // rebuild. The redirect must match one registered on the OAuth client (localhost is allowed for it).
    cf_oauth_client_id: []const u8 = "",
    cf_oauth_scopes: []const u8 = "account:read ai:write offline_access",
    cf_oauth_redirect: []const u8 = "http://localhost:8787/api/v1/oauth/cloudflare/callback",
    cf_oauth_auth_url: []const u8 = "https://dash.cloudflare.com/oauth2/auth",
    cf_oauth_token_url: []const u8 = "https://dash.cloudflare.com/oauth2/token",
    cf_oauth_accounts_url: []const u8 = "https://api.cloudflare.com/client/v4/accounts",
};

pub fn metered(app: *App, u: User) bool {
    return app.production and app.ledger != null and !app.auth.isAdmin(u);
}

pub fn requireUser(app: *App, req: *httpz.Request, res: *httpz.Response) ?User {
    // BANNED IS CHECKED HERE, on BOTH paths. setBanned drops the user's sessions, which closed the
    // cookie door — but an API key is verified straight against the key store and userById returns the
    // record regardless of `banned`, so a banned account holding an nlk_ key kept full access and ban
    // was not actually a moderation primitive. Login already refuses a banned user (auth_core:172);
    // this is the same refusal for a request that arrives already holding a credential.
    if (sessionToken(req)) |tok| if (app.auth.whoami(tok)) |u| {
        if (u.banned) { forbidden(res, "this account is suspended") catch {}; return null; }
        return u;
    };
    if (app.keys) |ks| if (apiKeyFromReq(req)) |k| if (ks.verify(k)) |uid| if (app.auth.userById(uid)) |u| {
        if (u.banned) { forbidden(res, "this account is suspended") catch {}; return null; }
        return u;
    };
    unauth(res) catch {};
    return null;
}

fn forbidden(res: *httpz.Response, msg: []const u8) !void {
    res.status = 403;
    try res.json(.{ .ok = false, .err = msg }, .{});
}

pub fn apiKeyFromReq(req: *httpz.Request) ?[]const u8 {
    const h = req.header("authorization") orelse req.header("Authorization") orelse return null;
    const bearer = "Bearer ";
    const tok = if (std.mem.startsWith(u8, h, bearer)) std.mem.trim(u8, h[bearer.len..], " ") else std.mem.trim(u8, h, " ");
    return if (std.mem.startsWith(u8, tok, "nlk_")) tok else null;
}

pub fn requireAdmin(app: *App, req: *httpz.Request, res: *httpz.Response) ?User {
    const u = requireUser(app, req, res) orelse return null;
    if (!app.auth.isAdmin(u)) {
        unauth(res) catch {};
        return null;
    }
    return u;
}

pub fn sessionToken(req: *httpz.Request) ?[]const u8 {
    const cookie = req.header("cookie") orelse req.header("Cookie") orelse return null;
    var it = std.mem.splitScalar(u8, cookie, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, p, COOKIE ++ "=")) return p[COOKIE.len + 1 ..];
    }
    return null;
}

/// Append `data` to `path` as an O(1) positioned write at end-of-file: open-or-create WITHOUT truncating, no
/// whole-file rewrite. The file grows monotonically, so a byte-cursor reader (the events poller) never sees it
/// shrink. Zig 0.16 has no O_APPEND (CreateFileOptions has no append mode), so this emulates it with
/// statFile-then-writePositionalAll — correct only for ONE writer at a time. The process-wide mutex makes the
/// stat→write pair atomic across threads: control.jsonl in particular has multiple writers (the /control
/// endpoint + the detached turn thread), and without the lock two racing appends read the same offset and
/// clobber each other. Each append is a few microseconds, so contention is negligible. (The worker has its own
/// appendFile; this covers only the gateway/chat/control callers.)
var append_mtx: std.Io.Mutex = .init;

/// Hold the append lock across a caller's own read-modify-write of an append-log file. A whole-file rewrite
/// (e.g. dropping a durable-memory line) must be mutually exclusive with appendFile: without this a concurrent
/// append that lands between the rewrite's read and its write is clobbered. The caller MUST NOT call appendFile
/// while holding it (std.Io.Mutex is non-reentrant → deadlock); do the read + writeFile directly, then unlock.
pub fn appendLock(io: std.Io) void {
    append_mtx.lockUncancelable(io);
}
pub fn appendUnlock(io: std.Io) void {
    append_mtx.unlock(io);
}

pub fn appendFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    _ = alloc; // no scratch buffer needed for a positioned append
    append_mtx.lockUncancelable(io);
    defer append_mtx.unlock(io);
    const dir = std.Io.Dir.cwd();
    // The end-of-file offset MUST come from statFile of the path, NOT `f.length()` on a freshly
    // createFile(.truncate=false) handle — that returns 0 here (Windows/Io), so every write would land at offset
    // 0 and clobber the previous frame. ONLY FileNotFound legitimately means offset 0 (a new file); any OTHER
    // stat error (transient sharing violation, AV scan window, READ-denied ACL) must NOT collapse to 0 — that
    // clobbers an existing file. Skip the append on such an error (callers `catch {}`): a dropped frame is
    // recoverable, a clobbered durable-log head is not.
    const end: u64 = if (dir.statFile(io, path, .{})) |st| st.size else |e| switch (e) {
        error.FileNotFound => 0,
        else => return e,
    };
    const f = try dir.createFile(io, path, .{ .truncate = false }); // create if missing; open-at-0 without truncating if it exists
    defer f.close(io);
    try f.writePositionalAll(io, data, end);
}

pub fn jstr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try list.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [6]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
        } else try list.append(gpa, c),
    };
    try list.append(gpa, '"');
}

pub fn badReq(res: *httpz.Response, msg: []const u8) !void {
    res.status = 400;
    try res.json(.{ .ok = false, .err = msg }, .{});
}
pub fn capErr(res: *httpz.Response, msg: []const u8) !void {
    res.status = 429;
    try res.json(.{ .ok = false, .err = msg }, .{});
}
pub fn notFound(res: *httpz.Response) !void {
    res.status = 404;
    try res.json(.{ .ok = false, .err = "not found" }, .{});
}
pub fn serverErr(res: *httpz.Response, msg: []const u8) !void {
    res.status = 500;
    try res.json(.{ .ok = false, .err = msg }, .{});
}
pub fn unauth(res: *httpz.Response) !void {
    res.status = 401;
    try res.json(.{ .ok = false, .err = "unauthorized" }, .{});
}
pub fn authErr(res: *httpz.Response, e: anyerror) !void {
    res.status = switch (e) {
        error.EmailTaken => @as(u16, 409),
        error.BadCredentials => 401,
        else => 400,
    };
    try res.json(.{ .ok = false, .err = @errorName(e) }, .{});
}
