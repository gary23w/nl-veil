//! TEST-ONLY HTTP stand-in: a loopback server that answers every connection with canned bytes.
//!
//! Lifted verbatim out of config/local_models.zig, where it was private and named for one caller.
//! H11 asked for an in-repo stand-in so LLM routing can be exercised without an external endpoint;
//! the primitive already existed, it just could not be reached. Shared rather than copied on
//! purpose -- a second copy of a nine-line escaper is what ledger 0055 spent an entry undoing.
//!
//! Callers: config/local_models.zig (the Ollama probe), worker/llm.zig (the gateway call, and the curl calls
//! whose scratch dir it inspects mid-call through `startWatched`), worker/modelpull.zig (the weights download),
//! and config/cf_tunnel.zig + config/cf_r2.zig, which start it ROUTED (`startRouted`) because one Cloudflare
//! flow is many different calls.
//!
//! PORT 0, NOT A SCAN. `start` used to walk 47431 upward until a listen failed to fail - and on Windows it
//! never fails: Zig 0.16 binds through AFD with BIND_INFO.Mode = .Passive, AFD's address-REUSE share type,
//! so a second listen on a port that is already held succeeds, even in another process. Every stand-in
//! bound 47431, and when two test suites ran at once (several sessions testing on one machine) curl and
//! httpc connections landed in the OTHER process's stand-in: a tunnel provisioning test and a weights
//! download test failed on replies meant for someone else, one stand-in captured another suite's first
//! request, and one saw no connections at all. The port the OS assigns is private.

const std = @import("std");
const builtin = @import("builtin");

/// TEST ONLY. One canned answer for `Server.startRouted`: requests whose method is `method` and whose
/// target contains `path`. `times` > 0 retires the route after that many answers, so "fails once, then
/// succeeds" is two routes in that order; 0 answers for as long as the server runs.
pub const Route = struct { method: []const u8, path: []const u8, reply: []const u8, times: u32 = 0 };

/// TEST ONLY. Runs on the serve thread for each request once it has arrived whole, before its reply goes out
/// (`startWatched`): the client is connected and waiting, so a test sees the world as it is mid-call.
pub const OnRequest = *const fn () void;

const MAX_ROUTES = 16;
const MAX_CALLS = 32;
const CALL_LEN = 256;

/// TEST ONLY. A loopback server that answers EVERY connection with the same canned bytes, and counts
/// them. `stop` is safe no matter how many requests actually arrived: it raises the shutdown flag and
/// then dials its own port once, so a serve loop parked in `accept` always wakes and exits. Without
/// that, a test whose handler never dialed (the auth-gate one, on purpose) would leave the thread
/// blocked forever and hang the whole runner instead of failing.
pub const Server = struct {
    io: std.Io,
    server: std.Io.net.Server,
    port: u16,
    reply: []const u8,
    conns: std.atomic.Value(u32),
    closing: std.atomic.Value(bool),
    thread: std.Thread,
    /// The FIRST request as it arrived on the wire, head and body. Written by the serve thread and
    /// read with `request()` -- which is only safe AFTER `stop()` has joined that thread, so there is
    /// no lock here and none is needed. Only the first is kept: a test that wants to assert on what
    /// was SENT is asserting about one call, and keeping the rest would just invite a race about
    /// which one you are looking at.
    req: [32 << 10]u8 = undefined,
    req_len: usize = 0,
    /// `startRouted` only (empty otherwise): the answers chosen per request, and how often each was used.
    routes: []const Route = &.{},
    used: [MAX_ROUTES]u32 = undefined,
    /// Every request LINE ("METHOD target", version dropped) in arrival order, the first MAX_CALLS of
    /// them: what a test of a multi-call flow asserts on. Same rule as `req` -- read only after `stop()`.
    calls: [MAX_CALLS][CALL_LEN]u8 = undefined,
    call_lens: [MAX_CALLS]usize = undefined,
    call_count: usize = 0,
    /// `startWatched` only (null otherwise).
    on_request: ?OnRequest = null,

    /// Starts in place: the serve thread holds a pointer to this struct, so it must not be copied. A fixed
    /// `port` is NOT exclusive on Windows (see the file header); port 0 takes one the OS assigns.
    pub fn startAt(self: *Server, io: std.Io, port: u16, reply: []const u8) !void {
        return self.listenAt(io, port, reply, &.{}, null);
    }

    /// Starts on a private OS-assigned loopback port, read back into `port`.
    pub fn start(self: *Server, io: std.Io, reply: []const u8) !void {
        self.listenAt(io, 0, reply, &.{}, null) catch return error.SkipZigTest; // no loopback listener on this box
    }

    /// Like `start`, but each request gets the reply of the first `routes` entry that matches it and has
    /// uses left (see Route); a request none matches gets `fallback`. `routes` must outlive the server.
    pub fn startRouted(self: *Server, io: std.Io, routes: []const Route, fallback: []const u8) !void {
        if (routes.len > MAX_ROUTES) return error.TooManyRoutes;
        self.listenAt(io, 0, fallback, routes, null) catch return error.SkipZigTest;
    }

    /// Like `startRouted` (empty `routes`: every request gets `fallback`), and `on_request` runs for each request
    /// between its arrival and its reply (see OnRequest).
    pub fn startWatched(self: *Server, io: std.Io, routes: []const Route, fallback: []const u8, on_request: OnRequest) !void {
        if (routes.len > MAX_ROUTES) return error.TooManyRoutes;
        self.listenAt(io, 0, fallback, routes, on_request) catch return error.SkipZigTest;
    }

    fn listenAt(self: *Server, io: std.Io, port: u16, reply: []const u8, routes: []const Route, on_request: ?OnRequest) !void {
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
        self.server = try std.Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp });
        self.io = io;
        self.reply = reply;
        self.port = self.server.socket.address.getPort(); // the one the OS assigned, when `port` is 0
        self.conns = .init(0);
        self.closing = .init(false);
        // MUST be set here, not left to the field default: callers declare `var srv: Server =
        // undefined` (the serve thread takes a pointer, so the struct cannot be copied into place),
        // and `= undefined` skips defaults. Left as garbage, `capture`'s `req.len - req_len`
        // underflows and it memcpys past the buffer — a genuinely dangerous field to default.
        // The routed fields are the same kind: garbage `used` counts retire routes that never ran.
        self.req_len = 0;
        self.routes = routes;
        self.used = @splat(0);
        self.call_count = 0;
        self.on_request = on_request;
        self.thread = std.Thread.spawn(.{}, serve, .{self}) catch |e| {
            self.server.deinit(io);
            return e;
        };
    }

    fn serve(self: *Server) void {
        while (true) {
            const conn = self.server.accept(self.io) catch return;
            defer conn.close(self.io);
            if (self.closing.load(.acquire)) return; // that was stop()'s wake-up dial
            _ = self.conns.fetchAdd(1, .monotonic);
            // Drain the request head first. httpc writes the whole request before it reads, and a peer
            // that answers-and-closes without reading can reset the connection out from under it.
            var rbuf: [4 << 10]u8 = undefined;
            var rd = conn.reader(self.io, &rbuf);
            const first = self.req_len == 0;
            var clen: usize = 0;
            // The request line, copied out before the reader moves on: routing and the call log need it.
            var line0: [CALL_LEN]u8 = undefined;
            var line0_len: usize = 0;
            var head_lines: usize = 0;
            while (true) {
                const line = (rd.interface.takeDelimiter('\n') catch break) orelse break;
                if (first) self.capture(line);
                if (head_lines == 0) {
                    const t = std.mem.trimEnd(u8, line, "\r");
                    const end = std.mem.lastIndexOfScalar(u8, t, ' ') orelse t.len; // drop " HTTP/1.1"
                    line0_len = @min(end, line0.len);
                    @memcpy(line0[0..line0_len], t[0..line0_len]);
                }
                head_lines += 1;
                if (headerLen(line)) |n| clen = n;
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }
            // Then the body, so a test can assert what was SENT and not just that something arrived.
            // Read it even when not capturing: leaving it unread is the reset hazard the head drain
            // above exists to avoid.
            if (clen > 0) {
                var body_buf: [32 << 10]u8 = undefined;
                const n = @min(clen, body_buf.len);
                if (rd.interface.readSliceAll(body_buf[0..n])) {
                    if (first) self.capture(body_buf[0..n]);
                } else |_| {}
            }
            const call = line0[0..line0_len];
            if (self.call_count < MAX_CALLS) {
                @memcpy(self.calls[self.call_count][0..call.len], call);
                self.call_lens[self.call_count] = call.len;
                self.call_count += 1;
            }
            if (self.on_request) |f| f();
            var wbuf: [8 << 10]u8 = undefined;
            var wr = conn.writer(self.io, &wbuf);
            wr.interface.writeAll(self.pick(call)) catch {};
            wr.interface.flush() catch {};
        }
    }

    /// The reply for one request line: the first route matching it with uses left, else `reply`.
    fn pick(self: *Server, call: []const u8) []const u8 {
        const sp = std.mem.indexOfScalar(u8, call, ' ') orelse return self.reply;
        for (self.routes, 0..) |r, i| {
            if (r.times > 0 and self.used[i] >= r.times) continue;
            if (!std.mem.eql(u8, r.method, call[0..sp]) or std.mem.indexOf(u8, call[sp + 1 ..], r.path) == null) continue;
            self.used[i] += 1;
            return r.reply;
        }
        return self.reply;
    }

    fn capture(self: *Server, bytes: []const u8) void {
        const room = self.req.len - self.req_len;
        const n = @min(bytes.len, room);
        @memcpy(self.req[self.req_len..][0..n], bytes[0..n]);
        self.req_len += n;
    }

    /// The first request as it arrived, head and body. ONLY call after `stop()` — it joins the serve
    /// thread, which is what makes this lock-free read safe.
    pub fn request(self: *const Server) []const u8 {
        return self.req[0..self.req_len];
    }

    /// Where the first request with this method and `path` inside its target came, in arrival order, or
    /// null when none did. ONLY after `stop()`, like `request()`.
    pub fn firstCall(self: *const Server, method: []const u8, path: []const u8) ?usize {
        for (self.calls[0..self.call_count], self.call_lens[0..self.call_count], 0..) |*c, len, i| {
            const sp = std.mem.indexOfScalar(u8, c[0..len], ' ') orelse continue;
            if (std.mem.eql(u8, c[0..sp], method) and std.mem.indexOf(u8, c[sp + 1 .. len], path) != null) return i;
        }
        return null;
    }

    /// How many requests had this method and `path` inside their target. ONLY after `stop()`.
    pub fn countCalls(self: *const Server, method: []const u8, path: []const u8) usize {
        var n: usize = 0;
        for (self.calls[0..self.call_count], self.call_lens[0..self.call_count]) |*c, len| {
            const sp = std.mem.indexOfScalar(u8, c[0..len], ' ') orelse continue;
            if (std.mem.eql(u8, c[0..sp], method) and std.mem.indexOf(u8, c[sp + 1 .. len], path) != null) n += 1;
        }
        return n;
    }

    pub fn stop(self: *Server) void {
        self.closing.store(true, .release);
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(self.port) };
        if (std.Io.net.IpAddress.connect(&addr, self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
    }
};

/// `Content-Length: N` -> N, for any case. Anything else -> null.
fn headerLen(line: []const u8) ?usize {
    const k = "content-length:";
    if (line.len <= k.len) return null;
    for (line[0..k.len], k) |a, b| if (std.ascii.toLower(a) != b) return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, line[k.len..], " \t\r"), 10) catch null;
}

/// TEST ONLY. One HTTP/1.1 reply with real Content-Length framing, built at comptime from its body.
pub fn wire(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
}

test "stand-ins started side by side get ports of their own, so none answers another's client" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = if (builtin.os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = std.mem.span(std.c.environ) } } });
    defer threaded.deinit();
    const io = threaded.io();
    var one: Server = undefined;
    try one.start(io, wire("{\"who\":1}"));
    defer one.stop();
    var two: Server = undefined;
    try two.startRouted(io, &.{.{ .method = "GET", .path = "/x", .reply = wire("{\"who\":2}") }}, wire("{}"));
    defer two.stop();
    // The old scan put both on 47431: on Windows the second listen shares the port instead of failing.
    try std.testing.expect(one.port != 0);
    try std.testing.expect(two.port != 0);
    try std.testing.expect(one.port != two.port);
}
