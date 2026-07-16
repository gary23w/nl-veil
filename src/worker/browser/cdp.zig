//! Chrome DevTools Protocol client — a synchronous request/response wrapper over a minimal, self-contained
//! RFC-6455 WebSocket client built on std.Io.net (the same raw-socket layer httpc.zig uses). CDP is JSON-RPC
//! over one ws connection: we send `{"id":N,"method":...,"params":...,"sessionId":...}` and read frames until
//! the reply carrying our `id` arrives, discarding the interleaved event frames.
//!
//! WHY not the vendored websocket.zig client: it is a blocking raw-socket implementation that (a) sits off the
//! app's std.Io model and (b) implements read timeouts with std.posix.poll, whose `pollfd` is absent from this
//! Zig's Windows ws2_32 — so its read path does not compile on Windows here. CDP is plaintext loopback ws with
//! small text frames (plus a few multi-MB screenshot frames), so a purpose-built client is simpler than
//! forking a shared dependency and keeps us on std.Io like httpc.zig.
//!
//! WHY the explicit Host header: Chromium's DevTools endpoint validates the ws upgrade's Host header (a
//! DNS-rebinding guard) and rejects a request lacking a loopback Host — so connect() sends Host: 127.0.0.1:<port>.
//!
//! Reads are blocking (bounded by connection liveness, not a wall clock): every CDP command with an id gets a
//! reply, Page.navigate returns as soon as navigation is INITIATED, and readiness is polled at the JS layer —
//! so no single call waits unboundedly. A dead browser surfaces as a socket error mapped to error.Closed.

const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.browser);

pub const Error = error{ Connect, Handshake, Send, Closed, CdpError, BadReply, OutOfMemory };

pub const Cdp = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    rd: *Io.net.Stream.Reader, // heap-boxed: Io.Reader uses @fieldParentPtr, so its address must be stable
    wr: *Io.net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,
    msg: std.ArrayListUnmanaged(u8) = .empty, // reused frame-reassembly buffer
    next_id: u32 = 1,
    prng: u64 = 0, // splitmix64 state for ws mask keys (loopback masking is anti-proxy-cache, not a secret)

    /// Fill `out` with non-crypto pseudo-random bytes. RFC-6455 requires client frames to be masked with a
    /// per-frame key, but on a direct loopback connection the key need not be unpredictable — a cheap
    /// splitmix64 suffices and avoids depending on std.crypto.random (absent in this Zig) or a time source.
    fn nextBytes(self: *Cdp, out: []u8) void {
        var i: usize = 0;
        while (i < out.len) {
            self.prng +%= 0x9E3779B97F4A7C15;
            var z = self.prng;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            z ^= z >> 31;
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, z, .little);
            const n = @min(8, out.len - i);
            @memcpy(out[i .. i + n], b[0..n]);
            i += n;
        }
    }

    /// Connect + upgrade to `ws_path` on 127.0.0.1:`port`.
    pub fn connect(gpa: std.mem.Allocator, io: Io, port: u16, ws_path: []const u8) Error!Cdp {
        const addr = Io.net.IpAddress{ .ip4 = .loopback(port) };
        var stream = Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.Connect;
        errdefer stream.close(io);

        const rbuf = gpa.alloc(u8, 64 << 10) catch return error.OutOfMemory;
        errdefer gpa.free(rbuf);
        const wbuf = gpa.alloc(u8, 16 << 10) catch return error.OutOfMemory;
        errdefer gpa.free(wbuf);
        const rd = gpa.create(Io.net.Stream.Reader) catch return error.OutOfMemory;
        errdefer gpa.destroy(rd);
        const wr = gpa.create(Io.net.Stream.Writer) catch return error.OutOfMemory;
        errdefer gpa.destroy(wr);
        rd.* = stream.reader(io, rbuf);
        wr.* = stream.writer(io, wbuf);

        var self: Cdp = .{ .gpa = gpa, .io = io, .stream = stream, .rd = rd, .wr = wr, .rbuf = rbuf, .wbuf = wbuf, .prng = @intFromPtr(rd) ^ (@as(u64, port) << 16) ^ 0xC0FFEE };
        try self.handshake(port, ws_path);
        return self;
    }

    pub fn deinit(self: *Cdp) void {
        self.stream.close(self.io);
        self.msg.deinit(self.gpa);
        self.gpa.free(self.rbuf);
        self.gpa.free(self.wbuf);
        self.gpa.destroy(self.rd);
        self.gpa.destroy(self.wr);
    }

    fn handshake(self: *Cdp, port: u16, ws_path: []const u8) Error!void {
        var key_bin: [16]u8 = undefined;
        self.nextBytes(&key_bin);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_bin);

        const w = &self.wr.interface;
        w.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ ws_path, port, key_b64 }) catch return error.Send;
        w.flush() catch return error.Send;

        const r = &self.rd.interface;
        const status = (r.takeDelimiter('\n') catch return error.Handshake) orelse return error.Handshake;
        if (std.mem.indexOf(u8, status, " 101") == null) {
            log.warn("cdp ws upgrade rejected: {s}", .{std.mem.trim(u8, status, " \r\n")});
            return error.Handshake;
        }
        // Drain the remaining response headers up to the blank line; leftover bytes stay buffered in the
        // reader and belong to the first ws frame.
        while (true) {
            const line = (r.takeDelimiter('\n') catch return error.Handshake) orelse return error.Handshake;
            if (std.mem.trim(u8, line, " \r\n").len == 0) break;
        }
    }

    pub fn call(self: *Cdp, method: []const u8, params_json: []const u8, session_id: ?[]const u8) Error![]u8 {
        return self.callTimeout(method, params_json, session_id, 0);
    }

    /// Issue one CDP command and return its `result` object as a gpa-owned JSON string (caller frees).
    /// `params_json` must be a JSON object string (pass "{}" for none). `session_id` targets a flattened
    /// target session (null = the browser-level session). A CDP `error` reply maps to error.CdpError.
    /// `timeout_ms` is currently advisory — see the module note on blocking reads.
    pub fn callTimeout(self: *Cdp, method: []const u8, params_json: []const u8, session_id: ?[]const u8, timeout_ms: u32) Error![]u8 {
        _ = timeout_ms;
        const id = self.next_id;
        self.next_id += 1;

        const params = if (std.mem.trim(u8, params_json, " \r\n\t").len == 0) "{}" else params_json;
        const req = if (session_id) |sid|
            std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"method\":\"{s}\",\"sessionId\":\"{s}\",\"params\":{s}}}", .{ id, method, sid, params }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params }) catch return error.OutOfMemory;
        defer self.gpa.free(req);

        try self.sendText(req);

        while (true) {
            const data = try self.readMessage();
            switch (self.matchReply(data, id)) {
                .miss => continue, // an event or a different id
                .err => return error.CdpError,
                .ok => |result| return result,
            }
        }
    }

    const Verdict = union(enum) { miss, err, ok: []u8 };

    fn matchReply(self: *Cdp, data: []const u8, id: u32) Verdict {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch return .miss;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .miss,
        };
        const id_val = obj.get("id") orelse return .miss; // no id ⇒ an event frame
        const got: i64 = switch (id_val) {
            .integer => |i| i,
            else => return .miss,
        };
        if (got != @as(i64, id)) return .miss;
        if (obj.get("error")) |ev| {
            const es = std.json.Stringify.valueAlloc(self.gpa, ev, .{}) catch "";
            defer if (es.len > 0) self.gpa.free(es);
            log.warn("cdp error on id {d}: {s}", .{ id, es });
            return .err;
        }
        const result = obj.get("result") orelse std.json.Value{ .null = {} };
        const out = std.json.Stringify.valueAlloc(self.gpa, result, .{}) catch return .err;
        return .{ .ok = out };
    }

    // ------------------------------------------------------------------------------------ RFC-6455 framing

    /// Send one masked text frame (client→server frames MUST be masked). Payload is small (a JSON command).
    fn sendText(self: *Cdp, payload: []const u8) Error!void {
        var key: [4]u8 = undefined;
        self.nextBytes(&key);
        var hdr: [14]u8 = undefined;
        hdr[0] = 0x81; // FIN + text opcode
        var hn: usize = 2;
        if (payload.len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xFFFF) {
            hdr[1] = 0x80 | 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            hn = 4;
        } else {
            hdr[1] = 0x80 | 127;
            std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
            hn = 10;
        }
        @memcpy(hdr[hn .. hn + 4], &key);
        hn += 4;

        const w = &self.wr.interface;
        w.writeAll(hdr[0..hn]) catch return error.Send;
        var i: usize = 0;
        var chunk: [2048]u8 = undefined;
        while (i < payload.len) {
            const n = @min(chunk.len, payload.len - i);
            for (0..n) |j| chunk[j] = payload[i + j] ^ key[(i + j) & 3];
            w.writeAll(chunk[0..n]) catch return error.Send;
            i += n;
        }
        w.flush() catch return error.Send;
    }

    /// Read one full ws message (reassembling continuation frames), auto-answering ping frames. Returns a
    /// slice into self.msg, valid until the next readMessage(). A close frame or socket error ⇒ error.Closed.
    fn readMessage(self: *Cdp) Error![]const u8 {
        self.msg.clearRetainingCapacity();
        const r = &self.rd.interface;
        while (true) {
            var h: [2]u8 = undefined;
            r.readSliceAll(&h) catch return error.Closed;
            const fin = (h[0] & 0x80) != 0;
            const opcode = h[0] & 0x0f;
            const masked = (h[1] & 0x80) != 0;
            var len: u64 = h[1] & 0x7f;
            if (len == 126) {
                var b: [2]u8 = undefined;
                r.readSliceAll(&b) catch return error.Closed;
                len = std.mem.readInt(u16, &b, .big);
            } else if (len == 127) {
                var b: [8]u8 = undefined;
                r.readSliceAll(&b) catch return error.Closed;
                len = std.mem.readInt(u64, &b, .big);
            }
            var mkey: [4]u8 = .{ 0, 0, 0, 0 };
            if (masked) r.readSliceAll(&mkey) catch return error.Closed; // servers don't mask; defensive

            switch (opcode) {
                0x8 => return error.Closed, // close
                0x9 => { // ping → pong (echo payload)
                    const pl = self.gpa.alloc(u8, len) catch return error.OutOfMemory;
                    defer self.gpa.free(pl);
                    r.readSliceAll(pl) catch return error.Closed;
                    if (masked) for (pl, 0..) |*b, k| {
                        b.* ^= mkey[k & 3];
                    };
                    self.sendPong(pl) catch {};
                },
                0xA => r.discardAll64(len) catch return error.Closed, // pong → drain
                0x0, 0x1, 0x2 => { // continuation / text / binary → append to the message
                    const start = self.msg.items.len;
                    self.msg.resize(self.gpa, start + len) catch return error.OutOfMemory;
                    r.readSliceAll(self.msg.items[start..]) catch return error.Closed;
                    if (masked) for (self.msg.items[start..], 0..) |*b, k| {
                        b.* ^= mkey[k & 3];
                    };
                    if (fin) return self.msg.items;
                },
                else => r.discardAll64(len) catch return error.Closed, // unknown control frame → skip
            }
        }
    }

    fn sendPong(self: *Cdp, payload: []const u8) Error!void {
        var key: [4]u8 = undefined;
        self.nextBytes(&key);
        var hdr: [14]u8 = undefined;
        hdr[0] = 0x8A; // FIN + pong
        hdr[1] = 0x80 | @as(u8, @intCast(@min(payload.len, 125))); // control payloads are <=125
        @memcpy(hdr[2..6], &key);
        const w = &self.wr.interface;
        w.writeAll(hdr[0..6]) catch return error.Send;
        const n = @min(payload.len, 125);
        var buf: [125]u8 = undefined;
        for (0..n) |j| buf[j] = payload[j] ^ key[j & 3];
        w.writeAll(buf[0..n]) catch return error.Send;
        w.flush() catch return error.Send;
    }
};
