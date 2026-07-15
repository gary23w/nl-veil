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
    const body = (try req.json(KeyReq)) orelse return badReq(res, "bad body");
    app.vault.put(u.id, body.provider, body.key, body.base_url) catch |e| return badReq(res, switch (e) {
        error.BadProvider => "invalid provider (use a-z0-9-_ , <=32 chars)",
        error.BadKey => "invalid key (1..512 chars, no quotes/backslashes/control chars)",
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
