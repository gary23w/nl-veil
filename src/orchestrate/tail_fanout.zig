//! Event delivery to the browser, two ways over the SAME events.jsonl cursor:

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const Supervisor = @import("supervisor.zig").Supervisor;
const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;
const unauth = http.unauth;
const serverErr = http.serverErr;

pub fn swarmEvents(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    const ev_path = try std.fmt.allocPrint(res.arena, "{s}/events.jsonl", .{sw.run_dir});
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, ev_path, res.arena, .limited(4 << 20)) catch "";
    var from: usize = 0;
    const q = try req.query();
    if (q.get("from") orelse q.get("offset")) |fs| from = std.fmt.parseInt(usize, fs, 10) catch 0;
    const slice = if (from <= data.len) data[from..] else data[0..0];
    res.header("X-Next-Offset", try std.fmt.allocPrint(res.arena, "{d}", .{data.len}));
    res.content_type = .EVENTS;
    res.body = slice;
}

const StreamCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    sup: *Supervisor,
    id: []const u8,
    run_dir: []const u8,
};

pub fn swarmStream(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    try startStream(app, res, id, sw.run_dir);
}

pub fn startStream(app: *App, res: *httpz.Response, id: []const u8, run_dir: []const u8) !void {
    const ctx = app.gpa.create(StreamCtx) catch return serverErr(res, "oom");
    ctx.io = app.io;
    ctx.gpa = app.gpa;
    ctx.sup = app.sup;
    ctx.id = app.gpa.dupe(u8, id) catch {
        app.gpa.destroy(ctx);
        return serverErr(res, "oom");
    };
    ctx.run_dir = app.gpa.dupe(u8, run_dir) catch {
        app.gpa.free(ctx.id);
        app.gpa.destroy(ctx);
        return serverErr(res, "oom");
    };
    try res.startEventStream(ctx, streamLoop);
}

fn streamLoop(ctx: *StreamCtx, stream: std.Io.net.Stream) void {
    defer {
        stream.close(ctx.io);
        ctx.gpa.free(ctx.id);
        ctx.gpa.free(ctx.run_dir);
        ctx.gpa.destroy(ctx);
    }
    var wbuf: [8192]u8 = undefined;
    var writer = stream.writer(ctx.io, &wbuf);
    const w = &writer.interface;
    var pbuf: [1280]u8 = undefined;
    const ev_path = std.fmt.bufPrint(&pbuf, "{s}/events.jsonl", .{ctx.run_dir}) catch return;

    w.writeAll(": connected\n\n") catch return;
    w.flush() catch return;

    var cursor: usize = 0;
    var idle: u32 = 0;
    while (true) {
        if (ctx.sup.get(ctx.id) == null) {
            w.writeAll("event: gone\ndata: {}\n\n") catch {};
            w.flush() catch {};
            break;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, ev_path, ctx.gpa, .limited(8 << 20)) catch "";
        defer if (data.len > 0) ctx.gpa.free(data);
        if (data.len < cursor) cursor = data.len;
        if (data.len > cursor) {
            var it = std.mem.splitScalar(u8, data[cursor..], '\n');
            while (it.next()) |raw| {
                const line = std.mem.trim(u8, raw, "\r");
                if (line.len == 0) continue;
                w.writeAll("data: ") catch return;
                w.writeAll(line) catch return;
                w.writeAll("\n\n") catch return;
            }
            w.flush() catch return;
            cursor = data.len;
            idle = 0;
        } else {
            idle += 1;
            if (idle % 30 == 0) {
                w.writeAll(": ping\n\n") catch return;
                w.flush() catch return;
            }
        }
        ctx.io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
    }
}
