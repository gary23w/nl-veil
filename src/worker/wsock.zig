//! wsock.zig — a blocking Winsock round trip under one wall-clock deadline, for the loopback HTTP client.
//!
//! TWIN FILE: src/worker/wsock.zig and desk/src/wsock.zig are byte-for-byte identical, this header included (the
//! desk and the server are separate Zig packages). Change both; `scripts/check.ps1 -Scan` and
//! `scripts/check.sh --scan` compare them.
//!
//! WHY THIS EXISTS. httpc's portable path bounds a request by racing it against a timer through the Io
//! runtime: two tasks on the runtime's pool, an await that parks the calling thread on its per-thread alert
//! (NtWaitForAlertByThreadId on Windows), and a cancel of the loser. That alert is one bit shared by everything
//! on the thread - the runtime's mutexes, conditions, sleeps and awaits, and Windows' own SRW locks and
//! WaitOnAddress inside any system call the thread makes. On 2026-09-02 the desk's poller and chat threads,
//! which make this round trip up to thirty times a second, were found parked in the runtime's sleep with no
//! timeout in effect, hours into a session, while the server in the same process kept answering in
//! milliseconds. The desk's loops now sleep through NtDelayExecution (desk/src/nap.zig); this file takes the
//! request itself off the runtime: one blocking socket, no tasks, no alerts, nothing to cancel. It is the model
//! httpz itself uses for its blocking worker.
//!
//! Scope: Windows, loopback or an IPv4 literal (the desk talking to its own server, the server's self-calls,
//! the CLI). A DNS name still goes through the portable path. Everything here is declared locally because this
//! std ships no Winsock bindings - its sockets are AFD handles that Winsock's recv/send would not accept.
const std = @import("std");
const builtin = @import("builtin");

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const IPPROTO_TCP: i32 = 6;
const SOL_SOCKET: i32 = 0xFFFF;
const SO_SNDTIMEO: i32 = 0x1005;
const SO_RCVTIMEO: i32 = 0x1006;
const SO_ERROR: i32 = 0x1007;
const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));
const WSAEWOULDBLOCK: i32 = 10035;
const WSAETIMEDOUT: i32 = 10060;
const WSAECONNREFUSED: i32 = 10061;

const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port_be: u16,
    addr: [4]u8,
    zero: [8]u8 = [_]u8{0} ** 8,
};

/// Winsock's fd_set with room for the one socket this file ever waits on: a u32 count, then the SOCKET array,
/// the same leading layout as the C struct. select() rewrites `count` to how many of them are ready.
const fd_set1 = extern struct {
    count: u32 = 1,
    fd: SOCKET,
};

const timeval = extern struct {
    sec: i32, // C `long`, which is 32 bits on Windows
    usec: i32,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, argp: *u32) callconv(.winapi) i32;
extern "ws2_32" fn select(nfds: i32, readfds: ?*fd_set1, writefds: ?*fd_set1, exceptfds: ?*fd_set1, timeout: *const timeval) callconv(.winapi) i32;
extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]u8, optlen: *i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;

var wsa_started = std.atomic.Value(bool).init(false);

fn ensureStarted() bool {
    if (wsa_started.load(.acquire)) return true;
    var data: [512]u8 = undefined;
    if (WSAStartup(0x0202, &data) != 0) return false; // reference-counted; a second call is harmless
    wsa_started.store(true, .release);
    return true;
}

/// "" -> loopback; "127.0.0.1" / "10.0.0.5" -> that address; a DNS name -> null (not ours to resolve).
pub fn ip4Of(host: []const u8) ?[4]u8 {
    if (host.len == 0 or std.mem.eql(u8, host, "localhost")) return .{ 127, 0, 0, 1 };
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 4 or part.len == 0 or part.len > 3) return null;
        out[n] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (n == 4) out else null;
}

pub const Outcome = union(enum) {
    ok: []u8, // the whole response, headers and body, owned by the caller
    refused,
    timed_out,
    failed,
};

/// One request, one blocking socket, one response read to the peer's close (the request carries
/// `Connection: close`, and httpz closes after the response). `timeout_s` bounds the WHOLE round trip: one
/// wall-clock deadline, taken before the socket exists, caps the connect (see connectBy) and every send and
/// receive, each of which gets SO_SNDTIMEO / SO_RCVTIMEO set to the time still left. A per-call timeout alone is
/// not a round-trip bound: a reply that went quiet just before the deadline used to hold the last receive for
/// up to another full `timeout_s`.
pub fn roundTrip(gpa: std.mem.Allocator, ip: [4]u8, port: u16, request: []const u8, timeout_s: u32, cap: usize) Outcome {
    if (builtin.os.tag != .windows) return .failed;
    if (!ensureStarted()) return .failed;
    const deadline = nowMs() + @as(i64, timeout_s) * 1000;
    const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return .failed;
    defer _ = closesocket(s);
    switch (connectBy(s, ip, port, deadline)) {
        .connected => {},
        .refused => return .refused,
        .timed_out => return .timed_out,
        .failed => return .failed,
    }
    var sent: usize = 0;
    while (sent < request.len) {
        const left = msLeft(deadline) orelse return .timed_out;
        if (setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, std.mem.asBytes(&left), @sizeOf(u32)) != 0) return .failed;
        const n = send(s, request[sent..].ptr, @intCast(@min(request.len - sent, 1 << 30)), 0);
        if (n <= 0) return if (WSAGetLastError() == WSAETIMEDOUT) .timed_out else .failed;
        sent += @intCast(n);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa); // empty again once toOwnedSlice has handed the bytes over
    var chunk: [16 << 10]u8 = undefined;
    while (true) {
        const left = msLeft(deadline) orelse return .timed_out;
        if (setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, std.mem.asBytes(&left), @sizeOf(u32)) != 0) return .failed;
        const n = recv(s, &chunk, chunk.len, 0);
        if (n == 0) break; // the peer closed: the response is complete
        if (n < 0) return if (WSAGetLastError() == WSAETIMEDOUT) .timed_out else .failed;
        out.appendSlice(gpa, chunk[0..@intCast(n)]) catch return .failed;
        if (out.items.len > cap + (256 << 10)) return .failed; // body cap plus generous headers
    }
    const raw = out.toOwnedSlice(gpa) catch return .failed;
    return .{ .ok = raw };
}

const Connected = enum { connected, refused, timed_out, failed };

/// connect() inside the deadline. A blocking connect takes no timeout on Windows - SO_SNDTIMEO does not apply to
/// it - and it waits out the stack's SYN retries: a refused loopback port answers after about 2 s, and an address
/// that drops SYNs holds the thread for about 21 s. So the connect runs non-blocking, select() waits for the time
/// left, SO_ERROR gives the verdict, and the socket goes back to blocking for the exchange.
fn connectBy(s: SOCKET, ip: [4]u8, port: u16, deadline: i64) Connected {
    var mode: u32 = 1; // non-blocking
    if (ioctlsocket(s, FIONBIO, &mode) != 0) return .failed;
    const addr: sockaddr_in = .{ .port_be = std.mem.nativeToBig(u16, port), .addr = ip };
    if (connect(s, &addr, @sizeOf(sockaddr_in)) != 0) {
        const e = WSAGetLastError();
        if (e == WSAECONNREFUSED) return .refused;
        if (e != WSAEWOULDBLOCK) return .failed;
        const left = msLeft(deadline) orelse return .timed_out;
        var writable: fd_set1 = .{ .fd = s };
        var failed: fd_set1 = .{ .fd = s };
        const tv: timeval = .{ .sec = @intCast(left / 1000), .usec = @intCast((left % 1000) * 1000) };
        const ready = select(0, null, &writable, &failed, &tv);
        if (ready == 0) return .timed_out;
        if (ready < 0) return .failed;
        if (failed.count != 0) { // Winsock reports a failed non-blocking connect in the exception set
            var err: i32 = 0;
            var len: i32 = @sizeOf(i32);
            if (getsockopt(s, SOL_SOCKET, SO_ERROR, std.mem.asBytes(&err), &len) != 0) return .failed;
            return switch (err) {
                WSAECONNREFUSED => .refused,
                WSAETIMEDOUT => .timed_out,
                else => .failed,
            };
        }
        if (writable.count == 0) return .failed;
    }
    mode = 0; // blocking again: the send and receive timeouts bound it from here
    if (ioctlsocket(s, FIONBIO, &mode) != 0) return .failed;
    return .connected;
}

/// Whole milliseconds left before `deadline`, at least 1 (a 0 socket timeout means "wait forever"), or null once
/// the deadline has passed.
fn msLeft(deadline: i64) ?u32 {
    const left = deadline - nowMs();
    if (left <= 0) return null;
    return @intCast(@min(left, std.math.maxInt(u32)));
}

fn nowMs() i64 {
    if (builtin.os.tag == .windows) {
        return @intCast(@divTrunc(std.os.windows.ntdll.RtlGetSystemTimePrecise(), 10_000));
    }
    return 0;
}

test "ip4Of: loopback by default, literals parsed, names refused" {
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ip4Of("").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ip4Of("localhost").?);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, ip4Of("10.0.0.5").?);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 20 }, ip4Of("192.168.1.20").?);
    try std.testing.expect(ip4Of("veil.example.com") == null);
    try std.testing.expect(ip4Of("1.2.3") == null);
    try std.testing.expect(ip4Of("1.2.3.4.5") == null);
    try std.testing.expect(ip4Of("300.1.1.1") == null);
    try std.testing.expect(ip4Of("1..2.3") == null);
}

test "sockaddr_in is the 16-byte wire layout with a big-endian port" {
    try std.testing.expectEqual(16, @sizeOf(sockaddr_in));
    const a: sockaddr_in = .{ .port_be = std.mem.nativeToBig(u16, 8787), .addr = .{ 127, 0, 0, 1 } };
    const bytes = std.mem.asBytes(&a);
    try std.testing.expectEqual(2, bytes[0]); // AF_INET
    try std.testing.expectEqual(0x22, bytes[2]); // 8787 = 0x2253, network order
    try std.testing.expectEqual(0x53, bytes[3]);
    try std.testing.expectEqual(127, bytes[4]);
}

test "fd_set1 matches the head of Winsock's fd_set: a u32 count, then the SOCKET array at pointer alignment" {
    try std.testing.expectEqual(0, @offsetOf(fd_set1, "count"));
    try std.testing.expectEqual(@alignOf(SOCKET), @offsetOf(fd_set1, "fd"));
    try std.testing.expectEqual(8, @sizeOf(timeval));
}

/// A one-connection loopback peer for the round-trip tests: real sockets, no Io runtime, no fixed port.
const test_peer = if (builtin.os.tag == .windows) struct {
    extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr_in, namelen: *i32) callconv(.winapi) i32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

    const Script = enum { answer_and_close, stall_after_one_byte };
    const Listener = struct { s: SOCKET, port: u16 };

    fn listenLoopback() !Listener {
        if (!ensureStarted()) return error.WinsockUnavailable;
        const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return error.NoSocket;
        errdefer _ = closesocket(s);
        var addr: sockaddr_in = .{ .port_be = 0, .addr = .{ 127, 0, 0, 1 } }; // port 0: the OS picks a free one
        if (bind(s, &addr, @sizeOf(sockaddr_in)) != 0) return error.BindFailed;
        if (listen(s, 4) != 0) return error.ListenFailed;
        var len: i32 = @sizeOf(sockaddr_in);
        if (getsockname(s, &addr, &len) != 0) return error.NoPort;
        return .{ .s = s, .port = std.mem.bigToNative(u16, addr.port_be) };
    }

    /// Serve ONE connection on `ls` by `script`, then close both sockets. Every wait is bounded, so a client
    /// that never shows up (or never leaves) cannot hang the test's join.
    fn serve(ls: SOCKET, script: Script) void {
        defer _ = closesocket(ls);
        var ready: fd_set1 = .{ .fd = ls };
        if (select(0, &ready, null, null, &.{ .sec = 10, .usec = 0 }) != 1) return;
        const c = accept(ls, null, null);
        if (c == INVALID_SOCKET) return;
        defer _ = closesocket(c);
        const ten_s: u32 = 10_000;
        _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, std.mem.asBytes(&ten_s), @sizeOf(u32));
        var buf: [4096]u8 = undefined;
        var got: usize = 0;
        while (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") == null and got < buf.len) {
            const n = recv(c, buf[got..].ptr, @intCast(buf.len - got), 0);
            if (n <= 0) return;
            got += @intCast(n);
        }
        switch (script) {
            .answer_and_close => {
                const reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
                _ = send(c, reply, reply.len, 0);
            },
            .stall_after_one_byte => {
                Sleep(1_500);
                _ = send(c, "H", 1, 0);
                _ = recv(c, &buf, buf.len, 0); // then silence, until the client gives up and closes
            },
        }
    }
} else struct {};

test "roundTrip: a whole exchange through the bounded connect - send, then read to the peer's close" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const l = try test_peer.listenLoopback();
    const peer = try std.Thread.spawn(.{}, test_peer.serve, .{ l.s, test_peer.Script.answer_and_close });
    defer peer.join();
    const req = "GET /x HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    switch (roundTrip(std.testing.allocator, .{ 127, 0, 0, 1 }, l.port, req, 5, 1 << 20)) {
        .ok => |raw| {
            defer std.testing.allocator.free(raw);
            try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", raw);
        },
        else => |other| {
            std.debug.print("\na live loopback peer answered .{t}\n", .{other});
            return error.RoundTripFailed;
        },
    }
}

test "roundTrip: timeout_s bounds the whole trip - a reply that stalls after its first byte ends on the deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const l = try test_peer.listenLoopback();
    const peer = try std.Thread.spawn(.{}, test_peer.serve, .{ l.s, test_peer.Script.stall_after_one_byte });
    defer peer.join();
    const t0 = nowMs();
    const out = roundTrip(std.testing.allocator, .{ 127, 0, 0, 1 }, l.port, "GET / HTTP/1.1\r\n\r\n", 2, 1 << 20);
    const took = nowMs() - t0;
    if (out == .ok) std.testing.allocator.free(out.ok);
    try std.testing.expect(out == .timed_out);
    // The byte lands at ~1.5 s. With only a per-call SO_RCVTIMEO the next receive waited a full 2 s more (~3.5 s).
    try std.testing.expect(took >= 1_900);
    try std.testing.expect(took < 2_900);
}

test "roundTrip: the connect is inside the bound too - an address that drops SYNs gives up on time" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // 192.0.2.1 is TEST-NET-1 (RFC 5737): unroutable, so SYNs vanish without a reset - a host that is down or
    // firewalled. A blocking connect sat through ~21 s of SYN retries whatever timeout_s said.
    const t0 = nowMs();
    const out = roundTrip(std.testing.allocator, .{ 192, 0, 2, 1 }, 9, "GET / HTTP/1.1\r\n\r\n", 1, 1 << 20);
    const took = nowMs() - t0;
    if (out == .ok) std.testing.allocator.free(out.ok);
    try std.testing.expect(out == .timed_out or out == .failed); // .failed: this machine has no route at all
    try std.testing.expect(took < 1_800);
}
