//! HTTP layer shared context — the `App` wiring struct plus the small helpers every handler reaches for:

const std = @import("std");
const httpz = @import("httpz");
const auth_core = @import("../auth/auth_core.zig");

pub const Auth = auth_core.Auth;
pub const User = auth_core.User;
pub const Supervisor = @import("../orchestrate/supervisor.zig").Supervisor;
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
    ledger: ?*NeuronLedger = null,
    keys: ?*ApiKeys = null,
};

pub fn metered(app: *App, u: User) bool {
    return app.production and app.ledger != null and !app.auth.isAdmin(u);
}

pub fn requireUser(app: *App, req: *httpz.Request, res: *httpz.Response) ?User {
    if (sessionToken(req)) |tok| if (app.auth.whoami(tok)) |u| return u;
    if (app.keys) |ks| if (apiKeyFromReq(req)) |k| if (ks.verify(k)) |uid| if (app.auth.userById(uid)) |u| return u;
    unauth(res) catch {};
    return null;
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

/// Append `data` to `path` as a TRUE O(1) append: open-or-create WITHOUT truncating, then a single positioned
/// write at the current end-of-file. The file grows monotonically (never rewritten), so:
///   * a byte-cursor reader (the chat events poller streams events.jsonl by offset) never sees the file shrink,
///   * a streaming turn emitting hundreds of token frames no longer pays an O(n²) whole-file rewrite per frame
///     (the old read-modify-write was the throttle that made streaming feel chunky), and
///   * the 8/64 MiB read-cap "amnesia cliff" is gone — nothing reads the existing content.
/// Open+close per call (like the worker's emit) so the file is never held locked against a concurrent reader.
pub fn appendFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    _ = alloc; // no scratch buffer needed for a positioned append
    const dir = std.Io.Dir.cwd();
    const f = try dir.createFile(io, path, .{ .truncate = false }); // create if missing; open-at-0 without truncating if it exists
    defer f.close(io);
    const end = f.length(io) catch 0;
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
