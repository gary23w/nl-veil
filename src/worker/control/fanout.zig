//! Event delivery to the browser over events.jsonl — offset polling (swarmEvents) and an SSE stream (swarmStream).

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("../../gateway/http.zig");
const evcursor = @import("../evcursor.zig"); // the poll cursor contract, shared with chat/service convEvents
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
    const q = try req.query();
    // The cursor contract (sentinel, page cap, offset arithmetic) lives in worker/evcursor.zig and is
    // SHARED with this endpoint's twin, chat/service.zig convEvents: the web console polls both with one
    // piece of client code, so a behavioral difference between them is a bug. It used to be duplicated
    // here under a "change one, change the other" comment.
    const from = evcursor.parseFrom(q.get("from") orelse q.get("offset"));
    // SIZE PROBE: answer the events file's TOTAL length as tiny JSON instead of a body, so a watcher can
    // baseline at the TAIL without transferring the backlog. Answers 200 even for a not-yet-written
    // events file (len 0).
    if (evcursor.isProbe(from)) {
        var size: usize = 0;
        if (std.Io.Dir.cwd().openFile(app.io, ev_path, .{})) |f| {
            defer f.close(app.io);
            size = std.math.cast(usize, f.length(app.io) catch 0) orelse 0;
        } else |_| {}
        return res.json(.{ .ok = true, .len = size }, .{});
    }
    // POSITIONAL read from the client's cursor `from` — NOT the whole file. This was readFileAlloc capped at
    // 4 MiB; a long run appends events.jsonl indefinitely, and once the file crossed the cap EVERY poll read
    // EMPTY, which reset the cursor to 0 and replayed history at the client. The file only grows, so `from`
    // stays valid; one poll's payload is bounded and the client catches up across polls. A quiet poll now
    // allocates and reads nothing.
    var body: []const u8 = "";
    var next_off: usize = from;
    if (std.Io.Dir.cwd().openFile(app.io, ev_path, .{})) |f| {
        defer f.close(app.io);
        const size: usize = std.math.cast(usize, f.length(app.io) catch 0) orelse 0;
        const want = evcursor.want(size, from);
        if (want > 0) {
            if (res.arena.alloc(u8, want)) |buf| {
                const n = f.readPositionalAll(app.io, buf, from) catch 0;
                body = buf[0..n];
                next_off = evcursor.nextOffset(from, n);
            } else |_| {} // OOM → empty this poll; the client re-polls (cursor unchanged)
        }
    } else |_| {} // no events.jsonl yet → empty body (a fresh run)
    res.header("X-Next-Offset", try std.fmt.allocPrint(res.arena, "{d}", .{next_off}));
    // .TEXT, deliberately NOT .EVENTS: bounded poll body. An empty .EVENTS response carries no Content-Length
    // (SSE framing = body ends at close), so a keep-alive client (the web console's poll loop) blocked until
    // the 60s idle reap on every empty poll. swarmStream below is the real SSE endpoint and keeps .EVENTS.
    res.content_type = .TEXT;
    res.body = body;
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

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md (Handlers). A swarm's events.jsonl is the whole run: its prompts,
// its outputs, every tool call. So the property under test is WHOSE events you can read, followed
// by the byte-cursor contract these endpoints publish (worker/evcursor.zig owns its unit tests;
// here it is exercised through the handler that clients actually call).
// ---------------------------------------------------------------------------

const Swarm = @import("supervisor.zig").Swarm;

/// TEST ONLY. Register a swarm owned by `uid` without launching anything (Supervisor.spawn starts a
/// real process). Caller frees via `dropTestSwarm`.
fn addTestSwarm(sup: *Supervisor, gpa: std.mem.Allocator, id: []const u8, uid: u64, run_dir: []const u8) !void {
    const sw = try gpa.create(Swarm);
    sw.* = .{
        .id = try gpa.dupe(u8, id),
        .uid = uid,
        .name = try gpa.dupe(u8, "test swarm"),
        .run_dir = try gpa.dupe(u8, run_dir),
        .model = try gpa.dupe(u8, "mock"),
        .minds = 1,
        .created = 0,
        .state = .running,
    };
    try sup.swarms.put(gpa, sw.id, sw);
}

fn dropTestSwarms(sup: *Supervisor, gpa: std.mem.Allocator) void {
    var it = sup.swarms.iterator();
    while (it.next()) |e| {
        const sw = e.value_ptr.*;
        gpa.free(sw.id); // also the map key — one allocation, freed once
        gpa.free(sw.name);
        gpa.free(sw.run_dir);
        gpa.free(sw.model);
        gpa.destroy(sw);
    }
    sup.swarms.deinit(gpa);
    sup.swarms = .empty;
}

test "a swarm's event stream is readable by its owner and nobody else" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-fanout-tmp");
    defer ta.deinit();
    defer dropTestSwarms(ta.app.sup, gpa);

    // Two accounts; uid 1 is admin by default, but ownership here is by uid, not by privilege —
    // which is the point: even the admin's own routes go through the same uid check.
    ta.auth.register("one@example.test", "correct horse battery") catch return error.SkipZigTest;
    ta.auth.register("two@example.test", "correct horse battery") catch return error.SkipZigTest;
    const tok_one = ta.auth.login("one@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(tok_one);
    const tok_two = ta.auth.login("two@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(tok_two);
    const cookie_one = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{tok_one});
    defer gpa.free(cookie_one);
    const cookie_two = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{tok_two});
    defer gpa.free(cookie_two);
    const uid_one = (ta.auth.whoami(tok_one) orelse return error.TestUnexpectedResult).id;

    // A swarm owned by account one, with a real events file behind it.
    const run_dir = "zig-fanout-tmp/run-one";
    _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch {};
    const EVENTS = "{\"t\":\"started\"}\n{\"t\":\"round\",\"n\":1}\n{\"t\":\"stopped\"}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = run_dir ++ "/events.jsonl", .data = EVENTS });
    try addTestSwarm(ta.app.sup, gpa, "sw-one", uid_one, run_dir);

    // a stranger
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.param("id", "sw-one");
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    // the OTHER account, properly logged in — the leak this check exists to prevent
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_two);
        web.param("id", "sw-one");
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(401);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, "round") == null); // no bytes leaked
    }
    // …and the SSE endpoint gates identically, before it ever takes over the socket
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_two);
        web.param("id", "sw-one");
        try swarmStream(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    // an id nobody owns is 404, not 401 — a client can tell "gone" from "not yours"
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        web.param("id", "sw-nope");
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(404);
    }
    // no id at all is a bad request
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(400);
    }
    // the owner reads the whole log, and is told where to resume
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        web.param("id", "sw-one");
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expectEqualStrings(EVENTS, web.res.body);
        var nb: [24]u8 = undefined;
        try web.expectHeader("X-Next-Offset", try std.fmt.bufPrint(&nb, "{d}", .{EVENTS.len}));
    }
}

test "the poll cursor a client is handed: caught-up is empty, and the probe answers a length" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-fanout-cursor-tmp");
    defer ta.deinit();
    defer dropTestSwarms(ta.app.sup, gpa);

    ta.auth.register("one@example.test", "correct horse battery") catch return error.SkipZigTest;
    const tok = ta.auth.login("one@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(tok);
    const cookie = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{tok});
    defer gpa.free(cookie);
    const uid = (ta.auth.whoami(tok) orelse return error.TestUnexpectedResult).id;

    const run_dir = "zig-fanout-cursor-tmp/run";
    _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch {};
    const EVENTS = "{\"t\":\"a\"}\n{\"t\":\"b\"}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = run_dir ++ "/events.jsonl", .data = EVENTS });
    try addTestSwarm(ta.app.sup, gpa, "sw", uid, run_dir);

    var offbuf: [24]u8 = undefined;
    const at_end = try std.fmt.bufPrint(&offbuf, "{d}", .{EVENTS.len});

    // caught up: nothing to send, cursor unchanged — the quiet poll that must not re-deliver
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        web.param("id", "sw");
        web.query("from", at_end);
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expectEqualStrings("", web.res.body);
        try web.expectHeader("X-Next-Offset", at_end);
    }
    // a cursor from the middle delivers only the remainder
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        web.param("id", "sw");
        web.query("from", "10");
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expectEqualStrings(EVENTS[10..], web.res.body);
    }
    // the size probe: a length, not a backlog — how a watcher baselines at the tail
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie);
        web.param("id", "sw");
        var pb: [32]u8 = undefined;
        web.query("from", try std.fmt.bufPrint(&pb, "{d}", .{evcursor.PROBE}));
        try swarmEvents(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        const body = (try web.getJson()).object;
        try std.testing.expect(body.get("ok").?.bool);
        try std.testing.expectEqual(@as(i64, EVENTS.len), body.get("len").?.integer);
    }
}
