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

// =====================================================================================================
// tests — the WIRE, not the browser.
//
// matchReply, readMessage, sendText, sendPong and nextBytes read only `gpa`, `prng`, `msg` and the two
// stream *interfaces*; not one of them touches `io` or `stream`. So a Cdp wired to a fixed reader over a
// canned frame stream and a fixed writer over a plain buffer drives the REAL demultiplexer and the REAL
// RFC-6455 framing with no socket, no port and no Chrome. Such a value is deliberately never deinit()'d:
// its socket fields stay undefined because nothing under test may read them, and that is the claim.
//
// Every frame below is one a live Chromium can put on this socket — or, for the malformed cases, one a
// broken or hostile peer can. connect()/handshake() are the only parts that genuinely need a listener and
// are therefore not covered here.
// =====================================================================================================

const testing = std.testing;

fn readerOver(bytes: []const u8) Io.net.Stream.Reader {
    var r: Io.net.Stream.Reader = undefined;
    r.interface = Io.Reader.fixed(bytes);
    return r;
}

fn writerOver(buf: []u8) Io.net.Stream.Writer {
    var w: Io.net.Stream.Writer = undefined;
    w.interface = Io.Writer.fixed(buf); // Writer.fixed's flush is a no-op, so the frame stays in `buf`
    return w;
}

fn wireCdp(rd: *Io.net.Stream.Reader, wr: *Io.net.Stream.Writer) Cdp {
    var c: Cdp = undefined;
    c.gpa = testing.allocator;
    c.rd = rd;
    c.wr = wr;
    c.msg = .empty;
    c.next_id = 1;
    c.prng = 0;
    return c;
}

/// Append one SERVER→client frame to `out`. Servers never mask, so this is the unmasked shape the read
/// path meets in production — and it is written independently of sendText, so the two cannot drift into
/// agreeing on a wrong encoding.
fn pushFrame(out: *std.ArrayListUnmanaged(u8), fin: bool, opcode: u8, payload: []const u8) !void {
    const gpa = testing.allocator;
    try out.append(gpa, (if (fin) @as(u8, 0x80) else @as(u8, 0)) | opcode);
    if (payload.len < 126) {
        try out.append(gpa, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        try out.append(gpa, 126);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(payload.len), .big);
        try out.appendSlice(gpa, &b);
    } else {
        try out.append(gpa, 127);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, payload.len, .big);
        try out.appendSlice(gpa, &b);
    }
    try out.appendSlice(gpa, payload);
}

fn expectMiss(c: *Cdp, frame: []const u8, id: u32) !void {
    switch (c.matchReply(frame, id)) {
        .miss => {},
        .err => return error.WantedMissGotCdpError,
        .ok => |s| {
            testing.allocator.free(s);
            return error.WantedMissGotAResult;
        },
    }
}

/// Read one message back out of bytes the CLIENT wrote — the mask/unmask round trip.
fn readBackOwned(sent: []const u8) ![]u8 {
    const gpa = testing.allocator;
    var rd = readerOver(sent);
    var scratch: [256]u8 = undefined;
    var wr = writerOver(&scratch);
    var c = wireCdp(&rd, &wr);
    defer c.msg.deinit(gpa);
    return gpa.dupe(u8, try c.readMessage());
}

test "matchReply hands back the result of the reply carrying OUR id, re-stringified" {
    const gpa = testing.allocator;
    var c: Cdp = undefined;
    c.gpa = gpa; // matchReply reads nothing else — that is the property this whole section rests on
    switch (c.matchReply("{\"id\":4,\"result\":{\"frameId\":\"A7\",\"loaderId\":\"L1\"}}", 4)) {
        .ok => |s| {
            defer gpa.free(s);
            try testing.expectEqualStrings("{\"frameId\":\"A7\",\"loaderId\":\"L1\"}", s);
        },
        else => return error.ExpectedResult,
    }
}

test "matchReply never hands back another call's reply: event frames and any non-matching id are misses" {
    const gpa = testing.allocator;
    var c: Cdp = undefined;
    c.gpa = gpa;
    // Exactly what a live CDP socket interleaves between our command and its reply. If ANY of these were
    // accepted, callTimeout would return one call's output as another's — silent cross-talk between two
    // browser commands, the single worst failure this demultiplexer can have.
    const not_ours = [_][]const u8{
        "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"1\"}}", // event: no id at all
        "{\"method\":\"Target.attachedToTarget\",\"sessionId\":\"S1\",\"params\":{}}",
        "{\"id\":3,\"result\":{\"stolen\":\"an earlier call's reply\"}}",
        "{\"id\":5,\"result\":{\"stolen\":\"a later call's reply\"}}",
        "{\"id\":\"4\",\"result\":{\"string id\":true}}", // a STRING id is not our integer id
        "{\"id\":4.0,\"result\":{\"float id\":true}}", // nor is a float
        "{\"id\":null,\"result\":{}}",
        "{\"error\":{\"code\":-32700,\"message\":\"an error with no id is nobody's\"}}",
    };
    for (not_ours) |f| try expectMiss(&c, f, 4);

    // ...and the genuine reply, arriving on the same connection, still matches.
    switch (c.matchReply("{\"id\":4,\"result\":{\"mine\":true}}", 4)) {
        .ok => |s| {
            defer gpa.free(s);
            try testing.expectEqualStrings("{\"mine\":true}", s);
        },
        else => return error.ExpectedResult,
    }
}

test "matchReply maps a JSON-RPC error object to .err — never to a result carrying the error payload" {
    const gpa = testing.allocator;
    var c: Cdp = undefined;
    c.gpa = gpa;
    // A CDP error reply often ALSO carries no result; the danger is answering .ok with the error text,
    // which the caller would hand to a model as if the command had succeeded.
    try testing.expect(c.matchReply("{\"id\":2,\"error\":{\"code\":-32000,\"message\":\"Cannot find context\"}}", 2) == .err);
    // error wins even when a result field sits beside it
    try testing.expect(c.matchReply("{\"id\":2,\"error\":{\"code\":-1},\"result\":{\"looks\":\"fine\"}}", 2) == .err);
    // ...but only for OUR id: another call's failure must not fail our call.
    try expectMiss(&c, "{\"id\":9,\"error\":{\"code\":-32000,\"message\":\"someone else's\"}}", 2);
}

test "matchReply: malformed and non-object frames are misses, so a garbled frame never becomes a result" {
    const gpa = testing.allocator;
    var c: Cdp = undefined;
    c.gpa = gpa;
    const garbage = [_][]const u8{
        "",
        "   ",
        "not json at all",
        "{\"id\":4,\"result\":", // truncated mid-object
        "[{\"id\":4,\"result\":{}}]", // an array, not an object
        "\"just a string\"",
        "4",
        "null",
        "{\"id\":4,\"result\":{}}trailing", // trailing junk after a valid object
    };
    for (garbage) |f| try expectMiss(&c, f, 4);
}

test "matchReply: a reply with no result field yields JSON null rather than failing the call" {
    const gpa = testing.allocator;
    var c: Cdp = undefined;
    c.gpa = gpa;
    // Several CDP commands (Page.enable, Input.dispatchKeyEvent) answer with a bare acknowledgement.
    switch (c.matchReply("{\"id\":6}", 6)) {
        .ok => |s| {
            defer gpa.free(s);
            try testing.expectEqualStrings("null", s);
        },
        else => return error.ExpectedResult,
    }
}

test "callTimeout walks the frame stream past events, other ids and noise and returns OUR reply" {
    const gpa = testing.allocator;
    var frames: std.ArrayListUnmanaged(u8) = .empty;
    defer frames.deinit(gpa);
    try pushFrame(&frames, true, 0x1, "{\"method\":\"Network.requestWillBeSent\",\"params\":{}}");
    try pushFrame(&frames, true, 0x1, "{\"id\":9,\"result\":{\"belongs\":\"to another call\"}}");
    try pushFrame(&frames, true, 0x1, "garbage that is not json");
    try pushFrame(&frames, true, 0x1, "{\"id\":1,\"result\":{\"value\":42}}");

    var rd = readerOver(frames.items);
    var wbuf: [4096]u8 = undefined;
    var wr = writerOver(&wbuf);
    var c = wireCdp(&rd, &wr);
    defer c.msg.deinit(gpa);

    const res = try c.callTimeout("Runtime.evaluate", "{\"expression\":\"1+1\"}", null, 0);
    defer gpa.free(res);
    try testing.expectEqualStrings("{\"value\":42}", res);
    try testing.expectEqual(@as(u32, 2), c.next_id); // one id consumed, so the next call cannot collide
}

test "callTimeout sends ONE masked text frame carrying its id, method and params — read back off the wire" {
    const gpa = testing.allocator;
    var empty: std.ArrayListUnmanaged(u8) = .empty;
    defer empty.deinit(gpa);
    try pushFrame(&empty, true, 0x1, "{\"id\":1,\"result\":{}}");

    var rd = readerOver(empty.items);
    var wbuf: [1024]u8 = undefined;
    var wr = writerOver(&wbuf);
    var c = wireCdp(&rd, &wr);
    defer c.msg.deinit(gpa);
    // blank params must become "{}": "params": with nothing after it is not JSON, and Chromium would
    // drop the connection rather than answer.
    const res = try c.callTimeout("Page.enable", "   ", "SESSION-7", 0);
    defer gpa.free(res);

    const sent = wr.interface.buffered();
    try testing.expectEqual(@as(u8, 0x81), sent[0]); // FIN + text
    try testing.expect((sent[1] & 0x80) != 0); // client frames MUST be masked (RFC-6455 5.3)

    const req = try readBackOwned(sent);
    defer gpa.free(req);
    const P = struct { id: i64 = 0, method: []const u8 = "", sessionId: []const u8 = "", params: std.json.Value = .null };
    const parsed = try std.json.parseFromSlice(P, gpa, req, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.id);
    try testing.expectEqualStrings("Page.enable", parsed.value.method);
    try testing.expectEqualStrings("SESSION-7", parsed.value.sessionId);
    try testing.expect(parsed.value.params == .object and parsed.value.params.object.count() == 0);
}

test "callTimeout maps a CDP error reply for our id to error.CdpError, and a dead stream to error.Closed" {
    const gpa = testing.allocator;
    var frames: std.ArrayListUnmanaged(u8) = .empty;
    defer frames.deinit(gpa);
    try pushFrame(&frames, true, 0x1, "{\"method\":\"Page.loadEventFired\",\"params\":{}}");
    try pushFrame(&frames, true, 0x1, "{\"id\":1,\"error\":{\"code\":-32000,\"message\":\"Cannot find context with specified id\"}}");
    var rd = readerOver(frames.items);
    var wbuf: [1024]u8 = undefined;
    var wr = writerOver(&wbuf);
    var c = wireCdp(&rd, &wr);
    defer c.msg.deinit(gpa);
    try testing.expectError(error.CdpError, c.callTimeout("Runtime.evaluate", "{}", null, 0));

    // The browser died (or answered nothing) — the loop must end, not spin or invent a result.
    var only_events: std.ArrayListUnmanaged(u8) = .empty;
    defer only_events.deinit(gpa);
    try pushFrame(&only_events, true, 0x1, "{\"method\":\"Page.loadEventFired\",\"params\":{}}");
    var rd2 = readerOver(only_events.items);
    var wbuf2: [1024]u8 = undefined;
    var wr2 = writerOver(&wbuf2);
    var c2 = wireCdp(&rd2, &wr2);
    defer c2.msg.deinit(gpa);
    try testing.expectError(error.Closed, c2.callTimeout("Runtime.evaluate", "{}", null, 0));
}

test "sendText header arithmetic: 125 keeps the 7-bit length, 126 and 65535 take 16 bits, 65536 takes 64" {
    const gpa = testing.allocator;
    // The three RFC-6455 length forms and both hinges between them. An off-by-one here writes a header
    // Chromium reads as a different length, and every later frame on the connection is misaligned.
    for ([_]usize{ 0, 1, 125, 126, 0xFFFF, 0x1_0000 }) |n| {
        const payload = try gpa.alloc(u8, n);
        defer gpa.free(payload);
        for (payload, 0..) |*b, i| b.* = @intCast((i *% 31 +% 7) & 0xff);

        const wbuf = try gpa.alloc(u8, n + 64);
        defer gpa.free(wbuf);
        var rd = readerOver("");
        var wr = writerOver(wbuf);
        var c = wireCdp(&rd, &wr);
        defer c.msg.deinit(gpa);
        try c.sendText(payload);

        const f = wr.interface.buffered();
        try testing.expectEqual(@as(u8, 0x81), f[0]);
        try testing.expect((f[1] & 0x80) != 0);
        const hn: usize = if (n < 126) blk: {
            try testing.expectEqual(@as(u8, @intCast(n)), f[1] & 0x7f);
            break :blk 2;
        } else if (n <= 0xFFFF) blk: {
            try testing.expectEqual(@as(u8, 126), f[1] & 0x7f);
            try testing.expectEqual(@as(u16, @intCast(n)), std.mem.readInt(u16, f[2..4], .big));
            break :blk 4;
        } else blk: {
            try testing.expectEqual(@as(u8, 127), f[1] & 0x7f);
            try testing.expectEqual(@as(u64, n), std.mem.readInt(u64, f[2..10], .big));
            break :blk 10;
        };
        // nothing over- or under-written: header + 4-byte mask key + payload, exactly
        try testing.expectEqual(hn + 4 + n, f.len);

        // and the mask is applied over the WHOLE payload, across the 2048-byte chunk seam
        const key = f[hn..][0..4];
        for (f[hn + 4 ..], 0..) |b, i| try testing.expectEqual(payload[i], b ^ key[i & 3]);

        // finally: our own reader recovers the payload byte for byte (mask and unmask agree)
        const back = try readBackOwned(f);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, payload, back);
    }
}

test "readMessage reassembles a fragmented message, and a ping between fragments does not corrupt it" {
    const gpa = testing.allocator;
    var frames: std.ArrayListUnmanaged(u8) = .empty;
    defer frames.deinit(gpa);
    try pushFrame(&frames, false, 0x1, "{\"id\":1,\"resu"); // text, FIN=0
    try pushFrame(&frames, true, 0x9, "hb"); // a ping interleaved between fragments (RFC-6455 5.4)
    try pushFrame(&frames, false, 0x0, "lt\":{\"big\":"); // continuation
    try pushFrame(&frames, true, 0xA, "unsolicited pong"); // must be drained, not appended
    try pushFrame(&frames, true, 0x0, "true}}"); // continuation, FIN=1

    var rd = readerOver(frames.items);
    var wbuf: [256]u8 = undefined;
    var wr = writerOver(&wbuf);
    var c = wireCdp(&rd, &wr);
    defer c.msg.deinit(gpa);

    const msg = try c.readMessage();
    try testing.expectEqualStrings("{\"id\":1,\"result\":{\"big\":true}}", msg);

    // the ping was answered with a masked pong echoing its payload — Chromium drops a peer that ignores pings
    const pong = wr.interface.buffered();
    try testing.expectEqual(@as(u8, 0x8A), pong[0]);
    try testing.expect((pong[1] & 0x80) != 0);
    try testing.expectEqual(@as(u8, 2), pong[1] & 0x7f);
    const key = pong[2..6];
    try testing.expectEqual(@as(u8, 'h'), pong[6] ^ key[0]);
    try testing.expectEqual(@as(u8, 'b'), pong[7] ^ key[1]);
    try testing.expectEqual(@as(usize, 8), pong.len); // and nothing else was written
}

test "readMessage: a close frame, a truncated header and a truncated payload all surface as error.Closed" {
    const gpa = testing.allocator;
    var closed: std.ArrayListUnmanaged(u8) = .empty;
    defer closed.deinit(gpa);
    try pushFrame(&closed, true, 0x8, "\x03\xe8"); // 1000 = normal closure
    {
        var rd = readerOver(closed.items);
        var wbuf: [64]u8 = undefined;
        var wr = writerOver(&wbuf);
        var c = wireCdp(&rd, &wr);
        defer c.msg.deinit(gpa);
        try testing.expectError(error.Closed, c.readMessage());
    }
    // header says 200 bytes, only 3 arrive: a browser killed mid-frame must not hang or read past the end
    {
        var rd = readerOver(&[_]u8{ 0x81, 200, 'a', 'b', 'c' });
        var wbuf: [64]u8 = undefined;
        var wr = writerOver(&wbuf);
        var c = wireCdp(&rd, &wr);
        defer c.msg.deinit(gpa);
        try testing.expectError(error.Closed, c.readMessage());
    }
    // and a stream that ends between the two header bytes
    {
        var rd = readerOver(&[_]u8{0x81});
        var wbuf: [64]u8 = undefined;
        var wr = writerOver(&wbuf);
        var c = wireCdp(&rd, &wr);
        defer c.msg.deinit(gpa);
        try testing.expectError(error.Closed, c.readMessage());
    }
}

test "readMessage: consecutive messages come back one at a time, each complete" {
    const gpa = testing.allocator;
    var frames: std.ArrayListUnmanaged(u8) = .empty;
    defer frames.deinit(gpa);
    try pushFrame(&frames, true, 0x1, "{\"first\":1}");
    try pushFrame(&frames, true, 0x2, "{\"second\":2}"); // binary opcode is treated as message data too
    var rd = readerOver(frames.items);
    var wbuf: [64]u8 = undefined;
    var wr = writerOver(&wbuf);
    var c = wireCdp(&rd, &wr);
    defer c.msg.deinit(gpa);
    // The reused reassembly buffer must not leak the previous message into the next one.
    try testing.expectEqualStrings("{\"first\":1}", try c.readMessage());
    try testing.expectEqualStrings("{\"second\":2}", try c.readMessage());
    try testing.expectError(error.Closed, c.readMessage());
}

test "nextBytes fills any length and never repeats the previous mask key" {
    var rd = readerOver("");
    var wbuf: [16]u8 = undefined;
    var wr = writerOver(&wbuf);
    var c = wireCdp(&rd, &wr);
    defer c.msg.deinit(testing.allocator);

    // zero length is a no-op, not a hang
    var none: [0]u8 = undefined;
    c.nextBytes(&none);

    // a non-multiple of the 8-byte splitmix64 word is filled to the last byte
    var a: [13]u8 = .{0} ** 13;
    c.nextBytes(&a);
    try testing.expect(!std.mem.allEqual(u8, &a, 0));

    // successive draws differ — RFC-6455 wants a fresh key per frame, and a stuck key would make every
    // frame's mask identical
    var k1: [4]u8 = undefined;
    var k2: [4]u8 = undefined;
    c.nextBytes(&k1);
    c.nextBytes(&k2);
    try testing.expect(!std.mem.eql(u8, &k1, &k2));

    // pure function of the state: same seed, same stream (this is what makes the frames above reproducible)
    var rd2 = readerOver("");
    var wr2 = writerOver(&wbuf);
    var c2 = wireCdp(&rd2, &wr2);
    defer c2.msg.deinit(testing.allocator);
    var b: [13]u8 = .{0} ** 13;
    c2.nextBytes(&b);
    try testing.expectEqualSlices(u8, &a, &b);
}
