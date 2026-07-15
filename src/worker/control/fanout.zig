//! Event delivery to the browser over events.jsonl — offset polling (swarmEvents) and an SSE stream (swarmStream).

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("../../gateway/http.zig");
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

// SSE hygiene. This loop is disowned onto a detached thread and never reads the socket, so it can't see a
// client's FIN between writes: a cleanly-closed socket lingers in CLOSE_WAIT until the next write fails, and
// a half-open peer (laptop sleep, crashed tab, dropped network — no FIN/RST arrives) would pin this thread +
// fd forever. Two guards: ping often enough that a clean close is caught in seconds (the write fails), and
// cap total lifetime so a half-open peer is recycled (the browser's EventSource auto-reconnects). httpz's
// keepalive timeout can't help — the connection is disowned out of its worker, so the stream self-polices.
// The loop runs on a RAW, detached std.Thread (response.zig startEventStream), NOT an Io-managed task: io.sleep
// throws there, and swallowing that error spins the loop at 100% CPU until the http pool starves. Sleep via
// the OS directly instead.
const winSleep = if (builtin.os.tag == .windows)
    struct {
        extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
    }.Sleep
else {};

fn tickSleep(io: std.Io) void {
    if (builtin.os.tag == .windows) {
        winSleep(@intCast(STREAM_TICK_MS));
    } else {
        io.sleep(.{ .nanoseconds = STREAM_TICK_MS * std.time.ns_per_ms }, .awake) catch {};
    }
}

const STREAM_TICK_MS: u64 = 500;
const PING_EVERY_TICKS: u32 = 10; // ~5s — bound how long a cleanly-closed socket lingers in CLOSE_WAIT
const MAX_STREAM_TICKS: u32 = (10 * 60 * 1000) / STREAM_TICK_MS; // ~10 min hard lifetime cap

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
    var ticks: u32 = 0;
    while (true) {
        if (ctx.sup.get(ctx.id) == null) {
            w.writeAll("event: gone\ndata: {}\n\n") catch {};
            w.flush() catch {};
            break;
        }
        // Hard lifetime cap: recycle the connection so a client that vanished without a FIN can't pin this
        // thread + socket (CLOSE_WAIT) indefinitely. Break WITHOUT an `event: gone` frame — that would tell
        // the browser the swarm is gone and stop its EventSource; a plain drop makes it reconnect instead.
        if (ticks >= MAX_STREAM_TICKS) break;
        // Cheap size check FIRST: only re-read the (growing, multi-MB) log once it has grown past what we've
        // already streamed — otherwise every 500ms tick pays an O(filesize) readFileAlloc, burning cores.
        const cur_size: usize = if (std.Io.Dir.cwd().statFile(ctx.io, ev_path, .{})) |st| @intCast(st.size) else |_| 0;
        if (cur_size < cursor) cursor = cur_size;
        if (cur_size > cursor) {
            const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, ev_path, ctx.gpa, .limited(8 << 20)) catch "";
            defer if (data.len > 0) ctx.gpa.free(data);
            const from = @min(cursor, data.len);
            var it = std.mem.splitScalar(u8, data[from..], '\n');
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
            if (idle % PING_EVERY_TICKS == 0) {
                w.writeAll(": ping\n\n") catch return;
                w.flush() catch return;
            }
        }
        tickSleep(ctx.io);
        ticks += 1;
    }
}
