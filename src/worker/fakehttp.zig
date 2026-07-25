//! TEST-ONLY HTTP stand-in: a loopback server that answers every connection with canned bytes.
//!
//! Lifted verbatim out of config/local_models.zig, where it was private and named for one caller.
//! H11 asked for an in-repo stand-in so LLM routing can be exercised without an external endpoint;
//! the primitive already existed, it just could not be reached. Shared rather than copied on
//! purpose -- a second copy of a nine-line escaper is what ledger 0055 spent an entry undoing.
//!
//! Callers: config/local_models.zig (the Ollama probe) and worker/llm.zig (the gateway call).
//! Tests run sequentially, so the port scan below cannot collide between them.

const std = @import("std");

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

    /// Starts in place: the serve thread holds a pointer to this struct, so it must not be copied.
    pub fn startAt(self: *Server, io: std.Io, port: u16, reply: []const u8) !void {
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
        self.server = try std.Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp });
        self.io = io;
        self.reply = reply;
        self.port = port;
        self.conns = .init(0);
        self.closing = .init(false);
        self.thread = std.Thread.spawn(.{}, serve, .{self}) catch |e| {
            self.server.deinit(io);
            return e;
        };
    }

    pub fn start(self: *Server, io: std.Io, reply: []const u8) !void {
        var port: u16 = 47431;
        while (port < 47530) : (port += 1) {
            self.startAt(io, port, reply) catch continue;
            return;
        }
        return error.SkipZigTest; // no free loopback port in the scan range
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
            while (true) {
                const line = (rd.interface.takeDelimiter('\n') catch break) orelse break;
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }
            var wbuf: [8 << 10]u8 = undefined;
            var wr = conn.writer(self.io, &wbuf);
            wr.interface.writeAll(self.reply) catch {};
            wr.interface.flush() catch {};
        }
    }

    pub fn stop(self: *Server) void {
        self.closing.store(true, .release);
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(self.port) };
        if (std.Io.net.IpAddress.connect(&addr, self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
    }
};

/// TEST ONLY. One HTTP/1.1 reply with real Content-Length framing, built at comptime from its body.
pub fn wire(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
}

