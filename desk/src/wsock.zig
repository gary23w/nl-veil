//! wsock.zig — a blocking Winsock round trip with socket-level timeouts, for the loopback HTTP client.
//!
//! WHY THIS EXISTS. httpc's portable path bounds a request by racing it against a timer through the Io
//! runtime: two tasks on the runtime's pool, an await that parks the calling thread on its per-thread alert
//! (NtWaitForAlertByThreadId on Windows), and a cancel of the loser. That alert is one bit shared by everything
//! on the thread - the runtime's mutexes, conditions, sleeps and awaits, and Windows' own SRW locks and
//! WaitOnAddress inside any system call the thread makes. On 2026-09-02 the desk's poller and chat threads,
//! which make this round trip up to thirty times a second, were found parked in the runtime's sleep with no
//! timeout in effect, hours into a session, while the server in the same process kept answering in
//! milliseconds. The desk's loops now sleep through NtDelayExecution (desk/src/nap.zig); this file takes the
//! request itself off the runtime: one blocking socket, SO_RCVTIMEO / SO_SNDTIMEO for the ceiling, no tasks,
//! no alerts, nothing to cancel. It is the model httpz itself uses for its blocking worker.
//!
//! Scope: Windows, loopback or an IPv4 literal (the desk talking to its own server, the server's self-calls,
//! the CLI). A DNS name still goes through the portable path. Everything here is declared locally because this
//! std ships no Winsock bindings - its sockets are AFD handles that Winsock's recv/send would not accept.
const std = @import("std");
const builtin = @import("builtin");

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
const SOCKET_ERROR: i32 = -1;
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const IPPROTO_TCP: i32 = 6;
const SOL_SOCKET: i32 = 0xFFFF;
const SO_SNDTIMEO: i32 = 0x1005;
const SO_RCVTIMEO: i32 = 0x1006;
const WSAETIMEDOUT: i32 = 10060;
const WSAECONNREFUSED: i32 = 10061;

const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port_be: u16,
    addr: [4]u8,
    zero: [8]u8 = [_]u8{0} ** 8,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
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
/// `Connection: close`, and httpz closes after the response). `timeout_s` bounds connect, each send and each
/// receive through SO_SNDTIMEO / SO_RCVTIMEO, and the whole round trip through a wall-clock deadline.
pub fn roundTrip(gpa: std.mem.Allocator, ip: [4]u8, port: u16, request: []const u8, timeout_s: u32, cap: usize) Outcome {
    if (builtin.os.tag != .windows) return .failed;
    if (!ensureStarted()) return .failed;
    const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return .failed;
    defer _ = closesocket(s);
    const ms: u32 = @intCast(@min(@as(u64, timeout_s) * 1000, std.math.maxInt(u32)));
    _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, std.mem.asBytes(&ms), @sizeOf(u32));
    _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, std.mem.asBytes(&ms), @sizeOf(u32));
    const addr: sockaddr_in = .{ .port_be = std.mem.nativeToBig(u16, port), .addr = ip };
    if (connect(s, &addr, @sizeOf(sockaddr_in)) != 0) {
        return if (WSAGetLastError() == WSAECONNREFUSED) .refused else .failed;
    }
    const deadline = nowMs() + @as(i64, timeout_s) * 1000;
    var sent: usize = 0;
    while (sent < request.len) {
        const n = send(s, request[sent..].ptr, @intCast(@min(request.len - sent, 1 << 30)), 0);
        if (n <= 0) return if (WSAGetLastError() == WSAETIMEDOUT) .timed_out else .failed;
        sent += @intCast(n);
        if (nowMs() > deadline) return .timed_out;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [16 << 10]u8 = undefined;
    while (true) {
        if (nowMs() > deadline) {
            out.deinit(gpa);
            return .timed_out;
        }
        const n = recv(s, &chunk, chunk.len, 0);
        if (n == 0) break; // the peer closed: the response is complete
        if (n < 0) {
            out.deinit(gpa);
            return if (WSAGetLastError() == WSAETIMEDOUT) .timed_out else .failed;
        }
        out.appendSlice(gpa, chunk[0..@intCast(n)]) catch {
            out.deinit(gpa);
            return .failed;
        };
        if (out.items.len > cap + (256 << 10)) { // body cap plus generous headers
            out.deinit(gpa);
            return .failed;
        }
    }
    const body = out.toOwnedSlice(gpa) catch return .failed;
    return .{ .ok = body };
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
