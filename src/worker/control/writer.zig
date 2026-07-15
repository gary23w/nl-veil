//! Control writer — POST /swarms/:id/control turns operator input (say / broadcast / set_goal / stop) into

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../../gateway/http.zig");
const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;
const unauth = http.unauth;
const serverErr = http.serverErr;
const jstr = http.jstr;
const appendFile = http.appendFile;

const ControlReq = struct { op: []const u8, to: []const u8 = "all", text: []const u8 = "", goal: []const u8 = "" };

pub fn swarmControl(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    const body = (try req.json(ControlReq)) orelse return badReq(res, "bad body");

    if (std.mem.eql(u8, body.op, "stop")) {
        app.sup.stop(id);
        try res.json(.{ .ok = true, .stopped = true }, .{});
        return;
    }
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(app.gpa);
    try line.appendSlice(app.gpa, "{\"op\":");
    try jstr(app.gpa, &line, body.op);
    if (body.text.len > 0) {
        try line.appendSlice(app.gpa, ",\"to\":");
        try jstr(app.gpa, &line, body.to);
        try line.appendSlice(app.gpa, ",\"text\":");
        try jstr(app.gpa, &line, body.text);
    }
    if (body.goal.len > 0) {
        try line.appendSlice(app.gpa, ",\"goal\":");
        try jstr(app.gpa, &line, body.goal);
    }
    try line.appendSlice(app.gpa, "}\n");
    const ctl_path = try std.fmt.allocPrint(res.arena, "{s}/control.jsonl", .{sw.run_dir});
    appendFile(app.io, res.arena, ctl_path, line.items) catch return serverErr(res, "could not write control");
    try res.json(.{ .ok = true }, .{});
}
