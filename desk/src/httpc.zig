//! httpc.zig — a bounded raw-socket HTTP/1.1 client for PLAIN-HTTP loopback endpoints: the local veil
//! server on :8787 and a local Ollama on :11434. Replaces a `curl` subprocess for that traffic.
//!
//! TWIN FILE: src/worker/httpc.zig is a byte-for-byte twin of everything below this header (desk and server
//! are separate Zig packages, so they can't share a module without cross-package build wiring). Fix a bug in
//! one → apply it to the other.
//!
//! WHY not curl: a curl subprocess puts the bearer token and JSON body on a child command line (readable by
//! any same-user process on Windows), and the spawn pattern — a self-built binary forking curl to POST bearer
//! JSON at localhost on the poller's cadence — is exactly what Defender's behavior/ML models flag. In-process
//! sockets have no argv and no child process.
//!
//! Timeout is a HARD ceiling. This client parses real HTTP framing — status line, headers, Content-Length or
//! chunked — so a well-behaved reply completes without waiting for close, and races the whole round trip
//! against an Io sleeper (`Io.Select`): `timeout_s` bounds connect+send+recv like curl --max-time.
//! Cancellation reaches a blocked read on every backend (on Windows the Threaded Io cancels the pending AFD
//! receive), so a wedged server surfaces as `.timed_out`, not a frozen thread. (A predecessor raw-socket
//! client read to EOF with no time bound, so a keep-alive server blocked the chat thread forever.)

const std = @import("std");
const Io = std.Io;

pub const Resp = struct {
    status: u16 = 0,
    body: []u8 = &.{}, // gpa-owned; caller frees when len>0
};

/// The caller-facing outcome netcli triages on: `refused` (nothing listening) and `timed_out` (server
/// wedged) both mean fail fast — retrying only multiplies the stall; `failed` (a transient "no status" reply)
/// is worth retrying when the request is idempotent.
pub const Result = union(enum) {
    ok: Resp,
    refused,
    timed_out,
    failed,
};

pub const Req = struct {
    method: []const u8, // "GET" | "POST" | "DELETE"
    host: []const u8 = "", // IP literal or DNS name; empty = the 127.0.0.1 loopback default
    port: u16,
    path: []const u8,
    bearer: []const u8 = "", // sent as Authorization: Bearer when non-empty — in-process only, never argv
    body: ?[]const u8 = null, // JSON; adds Content-Type + Content-Length
    timeout_s: u32, // hard ceiling on the WHOLE round trip (connect+send+recv)
    cap: usize = 1 << 20, // max body bytes; a bigger reply is a `.failed`, never unbounded memory
};

/// One bounded HTTP/1.1 round trip to <host>:<port> (default 127.0.0.1). Never blocks past `timeout_s`.
pub fn request(io: Io, gpa: std.mem.Allocator, req: Req) Result {
    const req_bytes = buildRequest(gpa, req) orelse return .failed;
    defer gpa.free(req_bytes);

    // Race the round trip against a sleeper. The round trip is spawned FIRST: if the backend is ever
    // out of concurrency and runs a task inline, we degrade to an unwatched (but framing-bounded)
    // request instead of always eating the full timeout before even connecting.
    const Race = union(enum) { rt: Inner, timer: void };
    var sbuf: [2]Race = undefined;
    var sel = Io.Select(Race).init(io, &sbuf);
    sel.async(.rt, roundTrip, .{ io, gpa, req.host, req.port, req_bytes, req.cap });
    sel.async(.timer, sleeper, .{ io, req.timeout_s });

    const first = sel.await() catch { // our own task was cancelled — drain children, then bail
        drain(gpa, &sel);
        return .failed;
    };
    const out: Result = switch (first) {
        .rt => |inner| switch (inner) {
            .ok => |resp| .{ .ok = resp },
            .refused => .refused,
            .failed => .failed,
        },
        .timer => .timed_out,
    };
    // Cancel the loser and drain: on timeout the round trip may still COMPLETE (with an allocated
    // body) between the timer firing and the cancel landing — that body must be freed, so use the
    // result-returning cancel loop rather than cancelDiscard.
    drain(gpa, &sel);
    return out;
}

fn drain(gpa: std.mem.Allocator, sel: anytype) void {
    while (sel.cancel()) |left| switch (left) {
        .rt => |inner| switch (inner) {
            .ok => |resp| if (resp.body.len > 0) gpa.free(resp.body),
            else => {},
        },
        .timer => {},
    };
}

fn sleeper(io: Io, seconds: u32) void {
    io.sleep(.{ .nanoseconds = @as(u64, seconds) * std.time.ns_per_s }, .awake) catch {};
}

const Inner = union(enum) {
    ok: Resp,
    refused,
    failed,
};

fn roundTrip(io: Io, gpa: std.mem.Allocator, host: []const u8, port: u16, req_bytes: []const u8, cap: usize) Inner {
    // Empty host = the loopback default. resolve() takes an IP literal or a DNS name, so a desk can drive
    // a remote veil; a name that won't resolve maps to .failed, which callers already treat as unreachable.
    const addr: Io.net.IpAddress = if (host.len == 0)
        .{ .ip4 = .loopback(port) }
    else
        Io.net.IpAddress.resolve(io, host, port) catch return .failed;
    // No connect timeout option: this Zig's Windows backend panics on one (netConnectIpWindows TODO),
    // and loopback connects resolve immediately either way — the Select sleeper bounds the rest.
    var stream = Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch |e| {
        return if (e == error.ConnectionRefused) .refused else .failed;
    };
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(req_bytes) catch return .failed;
    w.interface.flush() catch return .failed;

    // Header lines must fit this buffer (takeDelimiterExclusive is capacity-bounded); body bytes only
    // stream through it, so 16K is plenty for both peers we talk to (httpz and Ollama).
    var rbuf: [16 << 10]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    const resp = readResponse(&rd.interface, gpa, cap) catch return .failed;
    return .{ .ok = resp };
}

const cont = std.ascii; // case-insensitive header matching

/// Parse one HTTP/1.1 response off `r`: status line, headers, then the body per its REAL framing —
/// Content-Length when present, chunked when declared, read-to-EOF (capped) otherwise. Split from the
/// socket so it unit-tests against fixed buffers. Any framing violation is an error; the caller maps
/// it to a bounded failure instead of guessing at a truncated body.
pub fn readResponse(r: *Io.Reader, gpa: std.mem.Allocator, cap: usize) error{BadResponse}!Resp {
    // status line: HTTP/1.1 200 OK  (takeDelimiter consumes the '\n'; the Exclusive variant does NOT,
    // which would make every following line read come back empty)
    const line0 = (r.takeDelimiter('\n') catch return error.BadResponse) orelse return error.BadResponse;
    const status = parseStatusLine(std.mem.trimEnd(u8, line0, "\r")) orelse return error.BadResponse;

    var content_len: ?usize = null;
    var chunked = false;
    while (true) {
        const raw = (r.takeDelimiter('\n') catch return error.BadResponse) orelse return error.BadResponse;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break; // blank line: headers done
        if (headerValue(line, "content-length")) |v| {
            content_len = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch return error.BadResponse;
        } else if (headerValue(line, "transfer-encoding")) |v| {
            if (cont.indexOfIgnoreCase(v, "chunked") != null) chunked = true;
        }
    }

    // chunked wins over Content-Length per RFC 9112 §6.3 — a peer sending both is framing by chunks
    if (chunked) return readChunked(r, gpa, cap, status);
    if (content_len) |n| {
        if (n > cap) return error.BadResponse;
        const body = r.readAlloc(gpa, n) catch return error.BadResponse;
        return .{ .status = status, .body = body };
    }
    // no framing declared: Connection: close semantics — read until the server closes, capped
    const body = r.allocRemaining(gpa, .limited(cap)) catch return error.BadResponse;
    return .{ .status = status, .body = body };
}

fn readChunked(r: *Io.Reader, gpa: std.mem.Allocator, cap: usize, status: u16) error{BadResponse}!Resp {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    while (true) {
        const raw = (r.takeDelimiter('\n') catch return error.BadResponse) orelse return error.BadResponse;
        var sz = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOfScalar(u8, sz, ';')) |semi| sz = sz[0..semi]; // strip chunk extensions
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, sz, " \t"), 16) catch return error.BadResponse;
        if (n == 0) {
            // trailers: lines until a blank one; a server that closes right after `0\r\n` is fine too
            while (true) {
                const traw = (r.takeDelimiter('\n') catch break) orelse break;
                if (std.mem.trimEnd(u8, traw, "\r").len == 0) break;
            }
            break;
        }
        // overflow-safe: `list.items.len + n` would wrap usize on a hostile hex chunk size (up to 2^64-1),
        // which under ReleaseSafe traps and crashes the poller/chat thread — the exact frozen-thread failure
        // this client exists to avoid. Compare via subtraction so a huge n is a clean BadResponse.
        if (n > cap or list.items.len > cap - n) return error.BadResponse;
        list.ensureUnusedCapacity(gpa, n) catch return error.BadResponse;
        const dst = list.unusedCapacitySlice()[0..n];
        r.readSliceAll(dst) catch return error.BadResponse;
        list.items.len += n;
        const crlf = r.take(2) catch return error.BadResponse; // each chunk ends \r\n — anything else is desync
        if (!std.mem.eql(u8, crlf, "\r\n")) return error.BadResponse;
    }
    const body = list.toOwnedSlice(gpa) catch return error.BadResponse;
    return .{ .status = status, .body = body };
}

fn parseStatusLine(line: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, line, "HTTP/")) return null;
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const rest = line[sp + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const status = std.fmt.parseInt(u16, rest[0..end], 10) catch return null;
    return if (status >= 100 and status < 600) status else null;
}

fn headerValue(line: []const u8, comptime name: []const u8) ?[]const u8 {
    if (line.len < name.len + 1) return null;
    if (!cont.eqlIgnoreCase(line[0..name.len], name)) return null;
    if (line[name.len] != ':') return null;
    return line[name.len + 1 ..];
}

fn buildRequest(gpa: std.mem.Allocator, req: Req) ?[]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\nAccept: application/json\r\n", .{ req.method, req.path, if (req.host.len == 0) "127.0.0.1" else req.host, req.port }) catch return null;
    if (req.bearer.len > 0) w.print("Authorization: Bearer {s}\r\n", .{req.bearer}) catch return null;
    if (req.body) |b| {
        w.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{b.len}) catch return null;
        w.writeAll(b) catch return null;
    } else {
        w.writeAll("\r\n") catch return null;
    }
    return aw.toOwnedSlice() catch null;
}

/// A loopback plain-http URL like "http://127.0.0.1:11434" or "http://localhost:11434/some/base",
/// decomposed for `request`. Null for anything else (https, a remote host) — callers skip or keep
/// their fallback; this client is deliberately loopback-only.
pub const LoopbackUrl = struct {
    port: u16,
    path: []const u8, // prefix WITHOUT trailing slash; "" when the URL is bare
};

pub fn parseLoopbackUrl(url: []const u8) ?LoopbackUrl {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const hostport = rest[0..slash];
    const path = std.mem.trimEnd(u8, rest[slash..], "/");
    var host = hostport;
    var port: u16 = 80;
    if (std.mem.indexOfScalar(u8, hostport, ':')) |colon| {
        host = hostport[0..colon];
        port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return null;
    }
    // Only hosts this client can actually REACH: request() always dials IPv4 127.0.0.1, and a server on
    // 0.0.0.0 (INADDR_ANY) also listens there, so 0.0.0.0 is safe to serve in-process. [::1] is IPv6-only —
    // dialing IPv4 loopback would mis-reach it, so it is deliberately NOT loopback here and falls back to
    // curl (which dials it correctly). The admin gate in deploy_service treats [::1] as local independently.
    const loop = std.mem.eql(u8, host, "127.0.0.1") or cont.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "0.0.0.0");
    if (!loop) return null;
    return .{ .port = port, .path = path };
}

// ---------------------------------------------------------------------------
// tests — framing parser and URL splitter run on fixed buffers, no sockets
// ---------------------------------------------------------------------------

test "readResponse: Content-Length framing stops at the declared length (no EOF wait)" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}TRAILING-GARBAGE-AFTER-BODY";
    var r = Io.Reader.fixed(wire);
    const resp = try readResponse(&r, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);
}

test "readResponse: chunked framing with extensions and trailers reassembles the body" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "6;ext=1\r\n{\"ok\":\r\n5\r\ntrue}\r\n0\r\nX-Trailer: v\r\n\r\n";
    var r = Io.Reader.fixed(wire);
    const resp = try readResponse(&r, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);
}

test "readResponse: no framing headers falls back to read-to-EOF (Connection: close)" {
    const wire = "HTTP/1.1 404 Not Found\r\nServer: httpz\r\n\r\nnot here";
    var r = Io.Reader.fixed(wire);
    const resp = try readResponse(&r, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    try std.testing.expectEqualStrings("not here", resp.body);
}

test "readResponse: oversized and malformed replies are errors, never unbounded reads" {
    // Content-Length over cap
    var r1 = Io.Reader.fixed("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n");
    try std.testing.expectError(error.BadResponse, readResponse(&r1, std.testing.allocator, 10));
    // Content-Length body truncated by close
    var r2 = Io.Reader.fixed("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nshort");
    try std.testing.expectError(error.BadResponse, readResponse(&r2, std.testing.allocator, 1 << 20));
    // not HTTP at all
    var r3 = Io.Reader.fixed("SSH-2.0-OpenSSH_9.6\r\n");
    try std.testing.expectError(error.BadResponse, readResponse(&r3, std.testing.allocator, 1 << 20));
    // chunk size that isn't hex
    var r4 = Io.Reader.fixed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n");
    try std.testing.expectError(error.BadResponse, readResponse(&r4, std.testing.allocator, 1 << 20));
    // chunked body over cap
    var r5 = Io.Reader.fixed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nff\r\n");
    try std.testing.expectError(error.BadResponse, readResponse(&r5, std.testing.allocator, 8));
    // hostile chunk size after a real chunk: `list.items.len + n` would overflow usize and, under
    // ReleaseSafe, panic. Must be a clean BadResponse, not a crash.
    var r6 = Io.Reader.fixed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nX\r\nffffffffffffffff\r\n");
    try std.testing.expectError(error.BadResponse, readResponse(&r6, std.testing.allocator, 1 << 20));
}

test "readResponse: header names match case-insensitively and chunked beats Content-Length" {
    const wire = "HTTP/1.1 200 OK\r\ncontent-length: 999\r\nTRANSFER-ENCODING: Chunked\r\n\r\n" ++
        "2\r\nhi\r\n0\r\n\r\n";
    var r = Io.Reader.fixed(wire);
    const resp = try readResponse(&r, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("hi", resp.body);
}

test "parseLoopbackUrl accepts local http and rejects everything else" {
    const p1 = parseLoopbackUrl("http://127.0.0.1:11434").?;
    try std.testing.expectEqual(@as(u16, 11434), p1.port);
    try std.testing.expectEqualStrings("", p1.path);
    const p2 = parseLoopbackUrl("http://localhost:11434/custom/base/").?;
    try std.testing.expectEqual(@as(u16, 11434), p2.port);
    try std.testing.expectEqualStrings("/custom/base", p2.path);
    const p3 = parseLoopbackUrl("http://127.0.0.1/x").?;
    try std.testing.expectEqual(@as(u16, 80), p3.port);
    try std.testing.expect(parseLoopbackUrl("https://127.0.0.1:11434") == null); // no TLS here
    try std.testing.expect(parseLoopbackUrl("http://example.com:11434") == null); // not loopback
    try std.testing.expect(parseLoopbackUrl("http://127.0.0.1:notaport") == null);
    // 0.0.0.0 is served in-process (dialed via 127.0.0.1); [::1] is IPv6-only so it stays on curl (null)
    const p4 = parseLoopbackUrl("http://0.0.0.0:11434/v1").?;
    try std.testing.expectEqual(@as(u16, 11434), p4.port);
    try std.testing.expectEqualStrings("/v1", p4.path);
    try std.testing.expect(parseLoopbackUrl("http://[::1]:11434") == null);
}

test "buildRequest carries auth and body in-process (framing exact)" {
    const req = buildRequest(std.testing.allocator, .{
        .method = "POST",
        .port = 8787,
        .path = "/api/v1/cast",
        .bearer = "sekrit",
        .body = "{\"goal\":\"x\"}",
        .timeout_s = 5,
    }).?;
    defer std.testing.allocator.free(req);
    try std.testing.expectEqualStrings("POST /api/v1/cast HTTP/1.1\r\nHost: 127.0.0.1:8787\r\nConnection: close\r\nAccept: application/json\r\n" ++
        "Authorization: Bearer sekrit\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"goal\":\"x\"}", req);
}
