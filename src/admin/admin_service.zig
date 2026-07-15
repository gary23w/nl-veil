//! Admin (god-mode) HTTP handlers — list users, moderate (ban/unban/delete), list/kill swarms, read the audit log.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const ent = @import("../plan/entitlements.zig");
const App = http.App;
const requireAdmin = http.requireAdmin;
const badReq = http.badReq;
const notFound = http.notFound;

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
    res.content_type = .EVENTS;
    res.body = data;
}
