//! Tests for local patches in vendor/httpz's workers: the blocking worker veil's server runs on Windows, and the
//! nonblocking worker it runs everywhere else.
//!
//! 1. server.stop() closes each connection socket exactly once. Upstream's stop() closed every socket still on
//!    the worker's list, and a handler closed its socket a moment before taking it off that list. A stop()
//!    between the two closed the same SOCKET twice: check.ps1's src suite printed `WSAENOTSOCK` from
//!    worker.zig's listen. Now stop() only wakes the handlers, and each handler takes its socket off the list
//!    before closing it (worker.zig `Connections` has the measurements). Three tests use httpz's socket hook to
//!    run stop() where the old code broke: just before a handler's close, just after it, and inside
//!    res.disown(). They fail on any second or failed close.
//! 2. A request body cut short by the client's FIN closes the connection at once. Before, the worker went
//!    straight back to a recv that returned 0 and spun a thread at 100% CPU until the request deadline, and
//!    forever on a keep-alive request. A stopping server's shutdown reads as the same EOF.
//! 3. A stopped server leaves none of its threads running. The nonblocking worker freed its thread pool in
//!    deinit() without stopping it, and ThreadPool.deinit only freed the pool's arena, so the pool's threads
//!    stayed parked on a condition variable inside freed memory. On Linux a later futex wait there faulted, and
//!    the test run aborted in whichever test came next.
//!
//! 1 and 2 are Windows only: elsewhere httpz runs its nonblocking worker, which has no socket hook, and their
//! client is Winsock. 3 is Linux only, because it counts the process's threads in /proc/self/task.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("gateway/http.zig");

test "httpz stop: landing just before a Connection: close handler's close, each socket is still closed once" {
    try stopDuringClose(.closing);
}

test "httpz stop: landing just after a Connection: close handler's close, it never touches that socket" {
    try stopDuringClose(.closed);
}

/// K is an idle keep-alive connection and C a Connection: close request. server.stop() runs inside one of C's
/// events, on C's handler thread. `.closing` comes after the response went out, while C is still on stop()'s list.
/// `.closed` comes right after the handler closed C. The event returns once stop() has woken a socket (C for
/// `.closing`, K for `.closed`), so stop() is done with its list before the handler goes on.
fn stopDuringClose(trigger: httpz.Config.SocketEvent) !void {
    if (comptime builtin.os.tag != .windows or !httpz.blockingMode()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var rec: Recorder = .{ .io = io };
    errdefer rec.dump();
    const hook: httpz.Config.SocketHook = .{ .ctx = &rec, .event = Recorder.onEvent };
    var server = try httpz.Server(void).init(io, gpa, .{
        .address = .localhost(0),
        .thread_pool = .{ .count = 4 },
        .workers = .{ .socket_hook = &hook },
    }, {});
    defer server.deinit();
    var router = try server.router(.{});
    router.get("/", hello, .{});

    const thread = try server.listenInNewThread();
    const listener = server._listener orelse {
        thread.join();
        return error.ListenFailed;
    };
    var running = true;
    defer if (running) {
        if (!rec.stopDone()) server.stop();
        thread.join();
    };
    const port = try boundPort(listener);

    // K: one keep-alive request, then the connection stays open. Its handler goes back to recv and blocks there.
    const k = try Client.connect(port);
    defer k.close();
    try k.sendAll("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    var kbuf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try k.readResponse(&kbuf));
    win.Sleep(100);

    // C: upstream double-closed in both orderings. Before the handler's close, stop() closed C and the handler
    // then closed it again. After the handler's close, C was still on the list and stop() closed it again, which
    // is the WSAENOTSOCK check.ps1 printed.
    rec.stopInside(httpz.Server(void), &server, trigger, 1, if (trigger == .closing) 1 else 0);
    const c = try Client.connect(port);
    defer c.close();
    try c.sendAll("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    var cbuf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try c.readResponse(&cbuf));

    // Both handlers must be done within 5 s: C once the event returns, K once stop() cancels its recv. No
    // keep-alive timeout is configured, so nothing else would free K's handler.
    try rec.awaitCloses(2, 5000);
    thread.join();
    running = false;

    // A failed close is how a second close of the same SOCKET shows up (WSAENOTSOCK).
    try std.testing.expectEqual(@as(usize, 0), rec.count(.close_failed, null));
    try std.testing.expect(rec.stopDone());
    const k_socket = rec.nth(.tracked, 0) orelse return error.KNotTracked;
    const c_socket = rec.nth(.tracked, 1) orelse return error.CNotTracked;
    try std.testing.expectEqual(@as(usize, 2), rec.count(.tracked, null));
    for ([_]usize{ k_socket, c_socket }) |s| {
        try std.testing.expectEqual(@as(usize, 1), rec.count(.closing, s));
        try std.testing.expectEqual(@as(usize, 1), rec.count(.closed, s));
    }
    try std.testing.expectEqual(@as(usize, 0), rec.count(.handed_off, null));
    try std.testing.expectEqual(@as(usize, 1), rec.count(.woken, k_socket));
    switch (trigger) {
        // stop() reached C before its handler closed it: the ordering above really happened.
        .closing => {
            try std.testing.expectEqual(@as(usize, 1), rec.count(.woken, c_socket));
            try std.testing.expect(rec.indexOf(.woken, c_socket).? < rec.indexOf(.closed, c_socket).?);
        },
        // C left stop()'s list before its close, so stop(), which ran after that close, never touched the handle.
        .closed => {
            try std.testing.expectEqual(@as(usize, 0), rec.count(.woken, c_socket));
            try std.testing.expect(rec.indexOf(.closed, c_socket).? < rec.indexOf(.woken, k_socket).?);
        },
        else => unreachable,
    }

    // The server really ended both connections: the clients see them closed, not a timeout or a reset.
    try std.testing.expectEqual(Close.eof, k.awaitClose());
    try std.testing.expectEqual(Close.eof, c.awaitClose());
}

test "httpz stop: a socket that res.disown() gave away is left to its new owner" {
    if (comptime builtin.os.tag != .windows or !httpz.blockingMode()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var feed: Feed = .{ .io = io };
    // The stream thread writes through `io`, so it has to be done before `threaded` goes.
    defer feed.awaitFinished();
    var rec: Recorder = .{ .io = io };
    errdefer rec.dump();
    const hook: httpz.Config.SocketHook = .{ .ctx = &rec, .event = Recorder.onEvent };
    var server = try httpz.Server(*Feed).init(io, gpa, .{
        .address = .localhost(0),
        .thread_pool = .{ .count = 4 },
        .workers = .{ .socket_hook = &hook },
    }, &feed);
    defer server.deinit();
    var router = try server.router(.{});
    router.get("/", Feed.hello, .{});
    router.get("/events", Feed.events, .{});

    const thread = try server.listenInNewThread();
    const listener = server._listener orelse {
        thread.join();
        return error.ListenFailed;
    };
    var running = true;
    defer if (running) {
        if (!rec.stopDone()) server.stop();
        thread.join();
    };
    const port = try boundPort(listener);

    // K: an idle keep-alive connection. stop() wakes it, and that `.woken` is how the event below knows stop() ran.
    const k = try Client.connect(port);
    defer k.close();
    try k.sendAll("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    var kbuf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try k.readResponse(&kbuf));
    win.Sleep(100);

    // D: an event stream, the way veil's run feed serves one (res.startEventStream). server.stop() runs inside
    // D's `.handed_off` event, on the handler thread still inside res.disown(), and the event returns once stop()
    // has woken K. By then D must be off stop()'s list, so the stream thread still owns a working socket: it
    // writes its event and closes the socket itself.
    rec.stopInside(httpz.Server(*Feed), &server, .handed_off, 1, 0);
    const d = try Client.connect(port);
    defer d.close();
    try d.sendAll("GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    var dbuf: [512]u8 = undefined;
    const stream = try d.readToClose(&dbuf);

    try rec.awaitCloses(1, 5000);
    thread.join();
    running = false;
    feed.awaitFinished();

    try std.testing.expectEqual(@as(usize, 0), rec.count(.close_failed, null));
    try std.testing.expect(rec.stopDone());
    const k_socket = rec.nth(.tracked, 0) orelse return error.KNotTracked;
    const d_socket = rec.nth(.tracked, 1) orelse return error.DNotTracked;
    try std.testing.expectEqual(@as(usize, 1), rec.count(.handed_off, d_socket));
    // stop() never touched D, and httpz never closed it: the stream thread did.
    try std.testing.expectEqual(@as(usize, 0), rec.count(.woken, d_socket));
    try std.testing.expectEqual(@as(usize, 0), rec.count(.closing, d_socket));
    try std.testing.expectEqual(@as(usize, 0), rec.count(.closed, d_socket));
    try std.testing.expectEqual(@as(usize, 1), rec.count(.woken, k_socket));
    try std.testing.expectEqual(@as(usize, 1), rec.count(.closed, k_socket));
    try std.testing.expect(rec.indexOf(.handed_off, d_socket).? < rec.indexOf(.woken, k_socket).?);
    // The new owner kept a working socket: its event arrived, then its close.
    try std.testing.expect(std.mem.indexOf(u8, stream, "\r\n\r\ndata: hi\n\n") != null);
    try std.testing.expect(feed.finished.load(.acquire));
    try std.testing.expectEqual(Close.eof, k.awaitClose());
}

test "httpz: a request body cut short by the client's FIN closes the connection at once" {
    if (comptime builtin.os.tag != .windows or !httpz.blockingMode()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var rec: Recorder = .{ .io = io };
    errdefer rec.dump();
    const hook: httpz.Config.SocketHook = .{ .ctx = &rec, .event = Recorder.onEvent };
    var server = try httpz.Server(void).init(io, gpa, .{
        .address = .localhost(0),
        .thread_pool = .{ .count = 2 },
        // Bounds the spin this test guards against: without the fix the worker closes only when this deadline
        // passes, 5-6 s after the FIN.
        .timeout = .{ .request = 5 },
        .workers = .{ .socket_hook = &hook },
    }, {});
    defer server.deinit();
    var router = try server.router(.{});
    router.post("/", hello, .{});

    const thread = try server.listenInNewThread();
    const listener = server._listener orelse {
        thread.join();
        return error.ListenFailed;
    };
    defer {
        server.stop();
        thread.join();
    }
    const port = try boundPort(listener);

    const client = try Client.connect(port);
    defer client.close();
    try client.sendAll("POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100\r\n\r\n0123456789");
    // Let the server take the headers and those 10 bytes first, so the FIN lands in the body read.
    win.Sleep(100);
    if (win.shutdown(client.s, win.SD_SEND) != 0) return error.Shutdown;
    const t0 = win.GetTickCount64();
    try std.testing.expectEqual(Close.eof, client.awaitClose());
    try std.testing.expect(win.GetTickCount64() - t0 < 1000);

    try rec.awaitCloses(1, 5000);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.closed, null));
    try std.testing.expectEqual(@as(usize, 0), rec.count(.close_failed, null));
}

test "httpz: a stopped server leaves none of its threads running, its nonblocking workers' thread pools included" {
    if (comptime builtin.os.tag != .linux or httpz.blockingMode()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var server = try httpz.Server(void).init(io, gpa, .{
        .address = .localhost(0),
        .workers = .{ .count = 2 },
        .thread_pool = .{ .count = 4 },
    }, {});
    defer server.deinit();
    var router = try server.router(.{});
    router.get("/", hello, .{});

    const before = try threadCount(io);
    const thread = try server.listenInNewThread();
    if (server._listener == null) {
        thread.join();
        return error.ListenFailed;
    }
    // Serving: the listen thread, two event loops, and two pools of four.
    try std.testing.expect(try threadCount(io) >= before + 1 + 2 + 2 * 4);
    server.stop();
    thread.join();

    // listen() returns only after it has deinit'ed its workers, so every thread the server started should be gone.
    // A joined thread's /proc entry can outlive join() by a moment, so the count gets a second to settle. A pool
    // thread left parked never exits, and then the count stays above where it started.
    var after = try threadCount(io);
    var waits: usize = 0;
    while (after > before and waits < 100) : (waits += 1) {
        io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
        after = try threadCount(io);
    }
    if (after > before) std.debug.print("\n{d} thread(s) outlived the stopped server\n", .{after - before});
    try std.testing.expect(after <= before);
}

/// Linux: the process's live threads, one /proc/self/task entry each.
fn threadCount(io: std.Io) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, "/proc/self/task", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

fn hello(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = "hello";
}

/// The disown test's handler: /events gives its socket to a thread of its own, as veil's run feed does.
const Feed = struct {
    io: std.Io,
    started: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),

    fn hello(_: *Feed, _: *httpz.Request, res: *httpz.Response) !void {
        res.body = "hello";
    }

    fn events(feed: *Feed, _: *httpz.Request, res: *httpz.Response) !void {
        feed.started.store(true, .release);
        res.startEventStream(feed, run) catch |err| {
            feed.finished.store(true, .release);
            return err;
        };
    }

    /// The socket's new owner: one event, then it closes the socket.
    fn run(feed: *Feed, stream: std.Io.net.Stream) void {
        defer feed.finished.store(true, .release);
        var buf: [64]u8 = undefined;
        var writer = stream.writer(feed.io, &buf);
        writer.interface.writeAll("data: hi\n\n") catch {};
        writer.interface.flush() catch {};
        stream.close(feed.io);
    }

    fn awaitFinished(feed: *Feed) void {
        if (!feed.started.load(.acquire)) return;
        const deadline = win.GetTickCount64() + 5000;
        while (!feed.finished.load(.acquire) and win.GetTickCount64() < deadline) win.Sleep(5);
    }
};

/// Keeps every socket event httpz reports, and can stop the server from inside one of them.
const Recorder = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    events: [32]Event = undefined,
    len: usize = 0,
    trigger: ?Trigger = null,
    stopped: bool = false,

    const Event = struct { kind: httpz.Config.SocketEvent, socket: usize };

    const Trigger = struct {
        kind: httpz.Config.SocketEvent,
        nth: usize,
        woken_nth: usize,
        server: *anyopaque,
        stop: *const fn (server: *anyopaque) void,
    };

    /// From now on, the first `kind` event of the `nth` socket the server tracks (counting from 0) calls
    /// server.stop() from inside the event. The event returns once stop() has woken the `woken_nth` tracked socket.
    fn stopInside(self: *Recorder, comptime S: type, server: *S, kind: httpz.Config.SocketEvent, nth_socket: usize, woken_nth: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.trigger = .{ .kind = kind, .nth = nth_socket, .woken_nth = woken_nth, .server = server, .stop = struct {
            fn stop(ptr: *anyopaque) void {
                const s: *S = @ptrCast(@alignCast(ptr));
                s.stop();
            }
        }.stop };
    }

    fn onEvent(ctx: *anyopaque, kind: httpz.Config.SocketEvent, socket: std.posix.socket_t) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const id = @intFromPtr(socket);
        const fire: ?Trigger = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.len == self.events.len) @panic("Recorder: more socket events than expected");
            self.events[self.len] = .{ .kind = kind, .socket = id };
            self.len += 1;
            const t = self.trigger orelse break :blk null;
            if (self.stopped or kind != t.kind or self.nthLocked(.tracked, t.nth) != id) break :blk null;
            self.stopped = true;
            break :blk t;
        };
        // On the handler thread. stop() itself only closes the listener; the sweep runs on the listen thread, so
        // waiting here for its `.woken` holds this handler back until the sweep is done.
        if (fire) |t| {
            t.stop(t.server);
            const deadline = win.GetTickCount64() + 5000;
            while (win.GetTickCount64() < deadline) {
                if (self.nth(.tracked, t.woken_nth)) |s| if (self.count(.woken, s) > 0) break;
                win.Sleep(1);
            }
        }
    }

    fn stopDone(self: *Recorder) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopped;
    }

    /// Events of `kind`, for `socket` or for any socket.
    fn count(self: *Recorder, kind: httpz.Config.SocketEvent, socket: ?usize) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.events[0..self.len]) |e| {
            if (e.kind == kind and (socket == null or e.socket == socket.?)) n += 1;
        }
        return n;
    }

    fn nth(self: *Recorder, kind: httpz.Config.SocketEvent, n: usize) ?usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.nthLocked(kind, n);
    }

    fn nthLocked(self: *Recorder, kind: httpz.Config.SocketEvent, n: usize) ?usize {
        var seen: usize = 0;
        for (self.events[0..self.len]) |e| {
            if (e.kind != kind) continue;
            if (seen == n) return e.socket;
            seen += 1;
        }
        return null;
    }

    fn indexOf(self: *Recorder, kind: httpz.Config.SocketEvent, socket: usize) ?usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.events[0..self.len], 0..) |e, i| {
            if (e.kind == kind and e.socket == socket) return i;
        }
        return null;
    }

    /// Prints every event, for a failing test.
    fn dump(self: *Recorder) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.print("\nsocket events:\n", .{});
        for (self.events[0..self.len], 0..) |e, i| std.debug.print("  {d}: {t} socket 0x{x}\n", .{ i, e.kind, e.socket });
    }

    /// Waits until httpz has closed `want` sockets (a failed close counts too, so a regression shows in the
    /// assertions and not as a timeout here).
    fn awaitCloses(self: *Recorder, want: usize, budget_ms: u64) !void {
        const deadline = win.GetTickCount64() + budget_ms;
        while (self.count(.closed, null) + self.count(.close_failed, null) < want) {
            if (win.GetTickCount64() >= deadline) return error.HandlersStillOpen;
            win.Sleep(5);
        }
    }
};

fn boundPort(listener: std.posix.socket_t) !u16 {
    var addr: win.sockaddr_in = undefined;
    var len: i32 = @sizeOf(win.sockaddr_in);
    if (win.getsockname(@intFromPtr(listener), &addr, &len) != 0) return error.GetSockName;
    return std.mem.bigToNative(u16, addr.port);
}

const Close = enum { eof, data, timeout, reset };

/// A loopback Winsock client whose every read gives up after 5 s, so a server that never answers or never
/// closes fails the test instead of hanging it.
const Client = struct {
    s: win.SOCKET,

    fn connect(port: u16) !Client {
        var wsa: [512]u8 = undefined;
        if (win.WSAStartup(0x0202, &wsa) != 0) return error.WSAStartup;
        const s = win.socket(win.AF_INET, win.SOCK_STREAM, win.IPPROTO_TCP);
        if (s == win.INVALID_SOCKET) return error.Socket;
        errdefer _ = win.closesocket(s);
        const timeout_ms: u32 = 5000;
        if (win.setsockopt(s, win.SOL_SOCKET, win.SO_RCVTIMEO, std.mem.asBytes(&timeout_ms), @sizeOf(u32)) != 0) return error.SetSockOpt;
        const addr: win.sockaddr_in = .{ .port = std.mem.nativeToBig(u16, port), .addr = .{ 127, 0, 0, 1 } };
        if (win.connect(s, &addr, @sizeOf(win.sockaddr_in)) != 0) return error.Connect;
        return .{ .s = s };
    }

    fn close(c: Client) void {
        _ = win.closesocket(c.s);
    }

    fn sendAll(c: Client, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = win.send(c.s, bytes[sent..].ptr, @intCast(bytes.len - sent), 0);
            if (n <= 0) return error.Send;
            sent += @intCast(n);
        }
    }

    /// Reads one response that carries a Content-Length and returns its body.
    fn readResponse(c: Client, buf: []u8) ![]const u8 {
        var len: usize = 0;
        while (true) {
            if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |head_end| {
                const marker = "\r\nContent-Length: ";
                const at = std.mem.indexOf(u8, buf[0..head_end], marker) orelse return error.NoContentLength;
                const digits_end = std.mem.indexOfPos(u8, buf[0 .. head_end + 2], at + marker.len, "\r\n").?;
                const body_len = try std.fmt.parseInt(usize, buf[at + marker.len .. digits_end], 10);
                const total = head_end + 4 + body_len;
                if (total > buf.len) return error.ResponseTooBig;
                if (len >= total) return buf[head_end + 4 .. total];
            }
            if (len == buf.len) return error.ResponseTooBig;
            const n = win.recv(c.s, buf[len..].ptr, @intCast(buf.len - len), 0);
            if (n <= 0) return error.ResponseCut;
            len += @intCast(n);
        }
    }

    /// Reads everything until the server closes the connection.
    fn readToClose(c: Client, buf: []u8) ![]const u8 {
        var len: usize = 0;
        while (len < buf.len) {
            const n = win.recv(c.s, buf[len..].ptr, @intCast(buf.len - len), 0);
            if (n == 0) return buf[0..len];
            if (n < 0) return error.NotClosed;
            len += @intCast(n);
        }
        return error.ResponseTooBig;
    }

    /// What the next read sees once the response is in.
    fn awaitClose(c: Client) Close {
        var b: [64]u8 = undefined;
        const n = win.recv(c.s, &b, b.len, 0);
        if (n > 0) return .data;
        if (n == 0) return .eof;
        return if (win.WSAGetLastError() == win.WSAETIMEDOUT) .timeout else .reset;
    }
};

const win = struct {
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
    const AF_INET: u16 = 2;
    const SOCK_STREAM: i32 = 1;
    const IPPROTO_TCP: i32 = 6;
    const SOL_SOCKET: i32 = 0xFFFF;
    const SO_RCVTIMEO: i32 = 0x1006;
    const SD_SEND: i32 = 1;
    const WSAETIMEDOUT: i32 = 10060;

    const sockaddr_in = extern struct {
        family: u16 = AF_INET,
        port: u16,
        addr: [4]u8,
        zero: [8]u8 = @splat(0),
    };

    extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr_in, namelen: *i32) callconv(.winapi) i32;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
};
