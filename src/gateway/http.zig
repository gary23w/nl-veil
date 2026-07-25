//! HTTP layer shared context — the `App` wiring struct plus the auth / JSON / error helpers every handler uses.

const std = @import("std");
const httpz = @import("httpz");
const auth_core = @import("../auth/auth_core.zig");
// The recipe-tool registry (admin-authored data recipes). Imported for its type only — http.zig holds the
// live handle so the admin routes and the turn executor share ONE registry. recipes.zig depends on nothing
// but std, so this adds no import cycle.
const recipes = @import("../worker/recipes.zig");
// The user-extension (plugin) + theme-workspace registry. Imported for its type only; like recipes it is
// held as a live pointer so the chat engine hooks, the tool executor, and the /themes + /plugins routes all
// read ONE registry. plug/plugins.zig imports the mcp client + lua + theme under src/plug — no cycle back
// into http.zig.
const plugins = @import("../plug/plugins.zig");

pub const Auth = auth_core.Auth;
pub const User = auth_core.User;
pub const Supervisor = @import("../worker/control/supervisor.zig").Supervisor;
pub const AuditLog = @import("../obs/audit_log.zig").AuditLog;
pub const LoginGuard = @import("../auth/login_guard.zig").LoginGuard;
pub const KeyVault = @import("../config/key_vault.zig").KeyVault;
pub const NeuronLedger = @import("../plan/neurons.zig").NeuronLedger;
pub const ApiKeys = @import("../auth/api_keys.zig").ApiKeys;
pub const ServerConfig = @import("../config/server_config.zig").ServerConfig;

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
    // SERVER-SET DEFAULT MODEL, and anything else the admin owns at runtime. Live, mutex-guarded and
    // persisted — see config/server_config.zig. It used to be two frozen strings read from the
    // environment at boot, which meant a restart to change a dropdown's worth of state.
    cfg: *ServerConfig,
    // The live recipe-tool registry, loaded once at startup from {data}/tools/ and hot-swapped (never freed in
    // place) when an admin authors or deletes a recipe. The admin routes (admin/admin_service.zig) rebuild and
    // swap this pointer; the turn executor reads it to resolve a sandboxed caller's granted recipe tools. It is
    // a pointer so a reload is an atomic swap: a turn that captured the old pointer keeps reading a valid
    // registry rather than one being mutated underfoot. Built by admin_service.buildRegistry — the one place
    // that knows the recipe dir and the built-in-name predicate the loader needs.
    recipes: *recipes.Registry,
    // The live plugin + theme registry, loaded once at startup from {data}/plugins and {data}/themes.
    // Null-safe everywhere it is read (engine hooks, tool dispatch, /api routes) so the whole feature is
    // INERT until wired — a server built without ever calling plugins.loadAll behaves exactly as before.
    // Reload is an atomic pointer swap (plugins.swap); a turn that captured the old pointer keeps reading a
    // valid registry, same discipline as `recipes`.
    plugs: ?*plugins.Registry = null,
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
        if (u.banned) {
            forbidden(res, "this account is suspended") catch {};
            return null;
        }
        return u;
    };
    if (app.keys) |ks| if (apiKeyFromReq(req)) |k| if (ks.verify(k)) |uid| if (app.auth.userById(uid)) |u| {
        if (u.banned) {
            forbidden(res, "this account is suspended") catch {};
            return null;
        }
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
/// statFile-then-writePositionalAll — correct only for ONE writer at a time. The per-path lock stripe makes the
/// stat→write pair atomic across threads: control.jsonl in particular has multiple writers (the /control
/// endpoint + the detached turn thread), and without the lock two racing appends read the same offset and
/// clobber each other. STRIPED, not process-wide: one global mutex serialized every append in the process —
/// every concurrent conversation's event frames queued behind whichever file the filesystem was slowest on
/// (an AV scan or sync-client touch stalls ONE file for seconds), coupling unrelated turns into one convoy.
/// Same-path appends still fully exclude each other; distinct paths only collide on a stripe hash collision,
/// which merely coarsens the lock. (The worker has its own appendFile; this covers gateway/chat/control.)
var append_mtxs: [16]std.Io.Mutex = @splat(.init);

fn appendStripe(path: []const u8) *std.Io.Mutex {
    return &append_mtxs[std.hash.Wyhash.hash(0, path) & (append_mtxs.len - 1)];
}

/// Hold `path`'s append stripe across a caller's own read-modify-write of that append-log file. A whole-file
/// rewrite (e.g. dropping a durable-memory line) must be mutually exclusive with appendFile on the SAME path:
/// without this a concurrent append that lands between the rewrite's read and its write is clobbered. The
/// caller MUST NOT call appendFile on that path while holding it (std.Io.Mutex is non-reentrant → deadlock);
/// do the read + writeFile directly, then unlock with the same path.
pub fn appendLock(io: std.Io, path: []const u8) void {
    appendStripe(path).lockUncancelable(io);
}
pub fn appendUnlock(io: std.Io, path: []const u8) void {
    appendStripe(path).unlock(io);
}

pub fn appendFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    _ = alloc; // no scratch buffer needed for a positioned append
    const mtx = appendStripe(path);
    mtx.lockUncancelable(io);
    defer mtx.unlock(io);
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

// ---------------------------------------------------------------------------
// tests — the two primitives the rest of the server builds its guarantees on:
// jstr (every hand-rolled JSON line in this repo escapes through it) and appendFile
// (every append-log the byte-cursor readers poll). The handler helpers need an httpz
// Request/Response and are left to the endpoints' own coverage.
// ---------------------------------------------------------------------------

/// Escape `s` through jstr and hand back the quoted result (caller frees).
fn jstrAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    try jstr(gpa, &list, s);
    return list.toOwnedSlice(gpa);
}

test "jstr: the escapes are exactly the ones JSON requires, and control bytes go to \\u" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "\"\"" },
        .{ .in = "plain", .want = "\"plain\"" },
        .{ .in = "say \"hi\"", .want = "\"say \\\"hi\\\"\"" },
        .{ .in = "back\\slash", .want = "\"back\\\\slash\"" },
        .{ .in = "two\nlines", .want = "\"two\\nlines\"" },
        .{ .in = "cr\rtab\t", .want = "\"cr\\rtab\\t\"" },
        .{ .in = "\x01\x1f", .want = "\"\\u0001\\u001f\"" }, // other control bytes, never dropped
        .{ .in = "unicode ☃ stays raw", .want = "\"unicode ☃ stays raw\"" }, // >= 0x20 passes through
    };
    for (cases) |c| {
        const got = try jstrAlloc(gpa, c.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "jstr: hostile input round-trips through a real JSON parser instead of forging structure" {
    const gpa = std.testing.allocator;
    // Each of these is an attempt to break OUT of the string and add fields or records of its own —
    // the swarm control bus, the audit log and the chat event logs are all hand-rolled JSON lines,
    // so this escape is the only thing standing between a user-supplied string and forged structure.
    const hostile = [_][]const u8{
        "\",\"op\":\"stop\",\"x\":\"",
        "}\n{\"op\":\"stop\"}",
        "\\\",\"admin\":true,\"_\":\"",
        "line1\nline2\r\n{\"seq\":999}",
        "\x00\x07 bel and nul",
    };
    for (hostile) |s| {
        const escaped = try jstrAlloc(gpa, s);
        defer gpa.free(escaped);
        // it must still be ONE json string token...
        const doc = try std.fmt.allocPrint(gpa, "{{\"text\":{s},\"after\":1}}", .{escaped});
        defer gpa.free(doc);
        const P = struct { text: []const u8 = "", after: i64 = 0 };
        const parsed = try std.json.parseFromSlice(P, gpa, doc, .{});
        defer parsed.deinit();
        // ...whose value is byte-for-byte what went in, with the trailing field intact
        try std.testing.expectEqualStrings(s, parsed.value.text);
        try std.testing.expectEqual(@as(i64, 1), parsed.value.after);
        // and the escaped form never contains a bare newline that would split the line in two
        try std.testing.expect(std.mem.indexOfScalar(u8, escaped, '\n') == null);
    }
}

test "appendFile: the log only grows, in order, and a byte cursor never has to rewind" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-http-append-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    const path = root ++ "/events.jsonl";

    // A missing file is created at offset 0 — the only case allowed to start from nothing.
    try appendFile(io, gpa, path, "{\"i\":0}\n");
    // Every later append lands at end-of-file, so earlier frames survive verbatim.
    try appendFile(io, gpa, path, "{\"i\":1}\n");
    try appendFile(io, gpa, path, "{\"i\":2}\n");

    const all = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(all);
    try std.testing.expectEqualStrings("{\"i\":0}\n{\"i\":1}\n{\"i\":2}\n", all);

    // The property worker/evcursor.zig is written against: size is monotonic, so a reader's byte
    // cursor stays valid and the bytes after it are exactly what was appended since.
    const before = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
    try appendFile(io, gpa, path, "{\"i\":3}\n");
    const after = (try std.Io.Dir.cwd().statFile(io, path, .{})).size;
    try std.testing.expect(after > before);
    const tail = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(tail);
    try std.testing.expectEqualStrings("{\"i\":3}\n", tail[@intCast(before)..]);
}

test "appendStripe: a path always maps to its own lock, and the stripe is in range" {
    // Same path -> same mutex is the whole correctness argument for striping (two appends to one
    // file must exclude each other); different paths merely MAY share one, which only coarsens it.
    const a = appendStripe("data/u1/events.jsonl");
    try std.testing.expectEqual(a, appendStripe("data/u1/events.jsonl"));
    try std.testing.expectEqual(a, appendStripe("data/u1/events.jsonl"));

    var seen_distinct = false;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var buf: [64]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "data/u{d}/control.jsonl", .{i});
        const s = appendStripe(p);
        const idx = (@intFromPtr(s) - @intFromPtr(&append_mtxs[0])) / @sizeOf(std.Io.Mutex);
        try std.testing.expect(idx < append_mtxs.len); // never off the end of the stripe array
        if (s != a) seen_distinct = true;
    }
    try std.testing.expect(seen_distinct); // it really does spread, rather than funnelling into one
}
