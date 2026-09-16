//! portprobe.zig — is a TCP port already held on this machine? The question a fixed or scanned port asks
//! before it binds, answered in a way Windows does not fake.
//!
//! WHY THIS EXISTS. A bind that fails with AddressInUse is how a program usually learns a port is taken, and
//! on Windows neither binder in this tree ever fails that way. Zig 0.16's `std.Io.net.IpAddress.listen`
//! binds through AFD with BIND_INFO.Mode = .Passive, AFD's address-REUSE share type, and the vendored httpz
//! listener sets SO_REUSEADDR, which on Windows means "share the port with whoever holds it". Measured
//! 2026-09-16 on OS-assigned loopback ports: a second std listen on a held port succeeds, in the same process
//! or in another one. So the built-in engine endpoint's probe-bind and the Ollama test's default-port takeover
//! both read a held port as free, and two processes served one port.
//!
//! THE PROBE. One throwaway Winsock socket, AF_INET6 with IPV6_V6ONLY off (dual-stack) and SO_EXCLUSIVEADDRUSE
//! on, bound to [::]:port and closed without ever listening. An exclusive bind on the wildcard address is
//! refused by any socket already bound to that port on any local address (WSAEADDRINUSE, or WSAEACCES, which
//! Windows returns in some exclusive-holder cases), and the dual-stack socket carries that across both address
//! families. In the same measurements it was the only bind refused by every holder tried: std listens on
//! 127.0.0.1 and 0.0.0.0, and Winsock sockets in each share mode (default, SO_REUSEADDR, SO_EXCLUSIVEADDRUSE)
//! on 127.0.0.1, 0.0.0.0, dual-stack [::], IPv6-only [::] and [::1]. The narrower binds each miss something
//! real. An IPv4 exclusive bind on 127.0.0.1 misses a 0.0.0.0 holder. Every IPv4 bind, even exclusive on
//! 0.0.0.0, misses a dual-stack [::] listener, which is what a Go or Node server on a wildcard address opens.
//! That listener still answers 127.0.0.1, and it loses every loopback connection to the newcomer (8 of 8).
//!
//! It must never listen. Sockets bound to wildcard addresses and never listened on raised no Windows Firewall
//! prompt (measured), while a wildcard LISTEN raised one for each new executable path that made it: three
//! scratch binaries and three freshly built test binaries, the day this was written.
//!
//! Not held: TIME_WAIT connections left behind by a listener that closed (twenty such rows on a port, and the
//! probe still bound it), so a server restarted right after serving is never turned away. Also not held: a
//! closed listener's accepted connection that is still open. Rejected: a connect probe. A refused loopback
//! connect takes about two seconds on Windows (the SYN is retried) per candidate port, and it only sees
//! listeners that answer IPv4 loopback.
//!
//! POSIX is unchanged. There a listen on a held port does fail, so `held` is the throwaway std listen on
//! 127.0.0.1 that every caller already made.

const std = @import("std");
const builtin = @import("builtin");

/// Whether TCP `port` is already held on this machine: a listener, or any socket bound to that port on any
/// local address, IPv4 or IPv6. Windows: the exclusive dual-stack bind described in the header. POSIX: a
/// throwaway listen on 127.0.0.1:port. False when the probe cannot tell (no Winsock, or a bind failure that is
/// neither in-use nor access-denied), which leaves a caller doing what it did before this existed: attempting
/// the bind itself.
pub fn held(io: std.Io, port: u16) bool {
    if (builtin.os.tag == .windows) return winsock.exclusiveBind(port) == .held;
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var probe = std.Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch return true;
    probe.deinit(io);
    return false;
}

const Verdict = enum { free, held, unknown };

/// Everything is declared locally because this std ships no Winsock bindings (its sockets are AFD handles).
const winsock = struct {
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
    const AF_INET: i32 = 2;
    const AF_INET6: i32 = 23;
    const SOCK_STREAM: i32 = 1;
    const IPPROTO_TCP: i32 = 6;
    const IPPROTO_IPV6: i32 = 41;
    const IPV6_V6ONLY: i32 = 27;
    const SOL_SOCKET: i32 = 0xFFFF;
    const SO_REUSEADDR: i32 = 4;
    /// Winsock defines it as (int)(~SO_REUSEADDR).
    const SO_EXCLUSIVEADDRUSE: i32 = ~SO_REUSEADDR;
    const WSAEACCES: i32 = 10013;
    const WSAEADDRINUSE: i32 = 10048;

    const sockaddr_in = extern struct {
        family: u16 = 2,
        port_be: u16,
        addr: [4]u8 = .{ 0, 0, 0, 0 },
        zero: [8]u8 = [_]u8{0} ** 8,
    };
    const sockaddr_in6 = extern struct {
        family: u16 = 23,
        port_be: u16,
        flowinfo: u32 = 0,
        addr: [16]u8 = [_]u8{0} ** 16,
        scope_id: u32 = 0,
    };

    extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;

    var started = std.atomic.Value(bool).init(false);

    fn start() bool {
        if (started.load(.acquire)) return true;
        var data: [512]u8 = undefined;
        if (WSAStartup(0x0202, &data) != 0) return false; // reference-counted; a second call is harmless
        started.store(true, .release);
        return true;
    }

    /// The dual-stack bind, or the IPv4 wildcard bind when this machine gives no dual-stack socket: that still
    /// sees every IPv4 holder, it only loses sight of IPv6 ones.
    fn exclusiveBind(port: u16) Verdict {
        if (!start()) return .unknown;
        const v = bindOnce(port, .dual);
        if (v != .unknown) return v;
        return bindOnce(port, .ip4);
    }

    const Family = enum { dual, ip4 };

    /// One exclusive bind of `port` on the wildcard address, closed without listening.
    fn bindOnce(port: u16, family: Family) Verdict {
        const s = socket(if (family == .dual) AF_INET6 else AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return .unknown;
        defer _ = closesocket(s);
        const off: i32 = 0;
        const on: i32 = 1;
        if (family == .dual and setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, std.mem.asBytes(&off), @sizeOf(i32)) != 0) return .unknown;
        if (setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, std.mem.asBytes(&on), @sizeOf(i32)) != 0) return .unknown;
        const port_be = std.mem.nativeToBig(u16, port);
        const rc = switch (family) {
            .dual => bind(s, &sockaddr_in6{ .port_be = port_be }, @sizeOf(sockaddr_in6)),
            .ip4 => bind(s, &sockaddr_in{ .port_be = port_be }, @sizeOf(sockaddr_in)),
        };
        if (rc == 0) return .free;
        return switch (WSAGetLastError()) {
            WSAEADDRINUSE, WSAEACCES => .held,
            else => .unknown,
        };
    }
};

// ---- tests ---------------------------------------------------------------------------------------
//
// Every port here is one the OS assigned (a listen on port 0), never a fixed one: a fixed port may belong to
// something live on the machine, and on Windows a test that binds it shares it instead of failing.

/// TEST ONLY. N loopback listeners on OS-assigned ports.
const TestHolders = struct {
    const N = 8;
    servers: [N]std.Io.net.Server = undefined,
    ports: [N]u16 = undefined,
    open: usize = 0,

    fn listen(self: *TestHolders, io: std.Io) !void {
        while (self.open < N) {
            const any = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
            self.servers[self.open] = try std.Io.net.IpAddress.listen(&any, io, .{ .mode = .stream, .protocol = .tcp });
            self.ports[self.open] = self.servers[self.open].socket.address.getPort();
            self.open += 1;
        }
    }

    fn close(self: *TestHolders, io: std.Io) void {
        for (self.servers[0..self.open]) |*s| s.deinit(io);
        self.open = 0;
    }
};

test "a port another socket listens on is held, and asking holds nothing: once that socket closes the port is free" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h: TestHolders = .{};
    defer h.close(io);
    try h.listen(io);

    var seen: usize = 0;
    for (h.ports) |p| seen += @intFromBool(held(io, p));
    try std.testing.expectEqual(TestHolders.N, seen);
    // Asked twice: the probe closed its own socket, so it cannot be what the second answer sees.
    seen = 0;
    for (h.ports) |p| seen += @intFromBool(held(io, p));
    try std.testing.expectEqual(TestHolders.N, seen);

    h.close(io);
    var free: usize = 0;
    for (h.ports) |p| free += @intFromBool(!held(io, p));
    try std.testing.expectEqual(TestHolders.N, free);
}

test "on Windows a second std listen on a held port succeeds, the verdict every probe-bind reached, so held() never listens" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h: TestHolders = .{};
    defer h.close(io);
    try h.listen(io);

    // The old question, priced beside the new answer: how many held ports a second std listen still gets.
    // POSIX refuses every one of them. Windows grants every one of them, which is the blindness held() exists
    // for; if a future std makes this 0 on Windows too, the Windows probe has lost its reason.
    var shared: usize = 0;
    for (h.ports) |p| {
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(p) };
        var second = std.Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch continue;
        second.deinit(io);
        shared += 1;
    }
    const want: usize = if (builtin.os.tag == .windows) TestHolders.N else 0;
    try std.testing.expectEqual(want, shared);

    var seen: usize = 0;
    for (h.ports) |p| seen += @intFromBool(held(io, p));
    try std.testing.expectEqual(TestHolders.N, seen);
}

/// TEST ONLY (Windows). A Winsock socket on an OS-assigned port, shaped like the holders the narrower probes
/// miss. Only the loopback one listens. The wildcard ones are bound and never listen, which holds the port
/// against the probe exactly as a listener does (measured) and raises no Windows Firewall prompt; a wildcard
/// LISTEN in a test would raise one for every newly built test binary.
const TestWinHolder = struct {
    const Kind = enum {
        /// httpz's own listener: SO_REUSEADDR on 127.0.0.1 (the engine endpoint's shape) ...
        reuse_loopback,
        /// ... and on 0.0.0.0 (the main server's default bind).
        reuse_wildcard,
        /// A plain Winsock bind on 0.0.0.0, no options.
        default_wildcard,
        /// What a Go or Node server opens for a wildcard address, and what answers 127.0.0.1 all the same.
        dual_stack,
    };
    extern "ws2_32" fn listen(s: winsock.SOCKET, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn getsockname(s: winsock.SOCKET, name: *[28]u8, namelen: *i32) callconv(.winapi) i32;

    s: winsock.SOCKET,
    port: u16,

    fn open(kind: Kind) !TestWinHolder {
        if (!winsock.start()) return error.SkipZigTest;
        const W = winsock;
        const s = W.socket(if (kind == .dual_stack) W.AF_INET6 else W.AF_INET, W.SOCK_STREAM, W.IPPROTO_TCP);
        if (s == W.INVALID_SOCKET) return error.SkipZigTest; // no such stack on this machine: nothing to hold
        errdefer _ = W.closesocket(s);
        const off: i32 = 0;
        const on: i32 = 1;
        switch (kind) {
            .reuse_loopback, .reuse_wildcard => _ = W.setsockopt(s, W.SOL_SOCKET, W.SO_REUSEADDR, std.mem.asBytes(&on), @sizeOf(i32)),
            .default_wildcard => {},
            .dual_stack => if (W.setsockopt(s, W.IPPROTO_IPV6, W.IPV6_V6ONLY, std.mem.asBytes(&off), @sizeOf(i32)) != 0) return error.SkipZigTest,
        }
        const rc = switch (kind) {
            .reuse_loopback => W.bind(s, &W.sockaddr_in{ .port_be = 0, .addr = .{ 127, 0, 0, 1 } }, @sizeOf(W.sockaddr_in)),
            .reuse_wildcard, .default_wildcard => W.bind(s, &W.sockaddr_in{ .port_be = 0 }, @sizeOf(W.sockaddr_in)),
            .dual_stack => W.bind(s, &W.sockaddr_in6{ .port_be = 0 }, @sizeOf(W.sockaddr_in6)),
        };
        if (rc != 0) return error.TestUnexpectedResult;
        if (kind == .reuse_loopback and listen(s, 16) != 0) return error.TestUnexpectedResult;
        var name: [28]u8 = undefined;
        var len: i32 = name.len;
        if (getsockname(s, &name, &len) != 0) return error.TestUnexpectedResult;
        // sin_port and sin6_port share offset 2, in network order
        return .{ .s = s, .port = std.mem.readInt(u16, name[2..4], .big) };
    }

    fn close(self: TestWinHolder) void {
        _ = winsock.closesocket(self.s);
    }
};

test "held() sees the holders narrower binds miss: httpz's SO_REUSEADDR on 127.0.0.1 and 0.0.0.0, a plain 0.0.0.0 bind, a dual-stack [::] socket" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const reuse_lo = try TestWinHolder.open(.reuse_loopback);
    defer reuse_lo.close();
    const reuse_any = try TestWinHolder.open(.reuse_wildcard);
    defer reuse_any.close();
    const default_any = try TestWinHolder.open(.default_wildcard);
    defer default_any.close();
    const dual = try TestWinHolder.open(.dual_stack);
    defer dual.close();
    const ports = [_]u16{ reuse_lo.port, reuse_any.port, default_any.port, dual.port };

    var seen: usize = 0;
    for (ports) |p| seen += @intFromBool(held(io, p));
    try std.testing.expectEqual(ports.len, seen);

    // Priced beside it, the two cheaper answers. The probe-bind this replaces (a std listen on 127.0.0.1)
    // sees none of the four. The IPv4 wildcard bind, the fallback on a machine with no dual-stack socket,
    // sees all but the dual-stack socket.
    var old_seen: usize = 0;
    for (ports) |p| {
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(p) };
        var probe = std.Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch {
            old_seen += 1;
            continue;
        };
        probe.deinit(io);
    }
    try std.testing.expectEqual(@as(usize, 0), old_seen);
    var ip4_seen: usize = 0;
    for (ports) |p| ip4_seen += @intFromBool(winsock.bindOnce(p, .ip4) == .held);
    try std.testing.expectEqual(ports.len - 1, ip4_seen);
    try std.testing.expectEqual(Verdict.free, winsock.bindOnce(dual.port, .ip4));
}

extern "iphlpapi" fn GetTcpTable(table: ?[*]u8, size: *u32, order: i32) callconv(.winapi) u32;

/// TEST ONLY (Windows). IPv4 TCP table rows in TIME_WAIT whose local port is `port`.
fn timeWaitRows(port: u16) !usize {
    const MIB_TCP_STATE_TIME_WAIT = 11;
    const ROW = 20; // MIB_TCPROW: state, local addr, local port, remote addr, remote port (DWORDs)
    var size: u32 = 0;
    _ = GetTcpTable(null, &size, 0);
    const buf = try std.testing.allocator.alloc(u8, size + 64 * ROW); // room for rows that appear meanwhile
    defer std.testing.allocator.free(buf);
    size = @intCast(buf.len);
    if (GetTcpTable(buf.ptr, &size, 0) != 0) return error.TestUnexpectedResult;
    const n = std.mem.readInt(u32, buf[0..4], .little);
    var rows: usize = 0;
    for (0..n) |i| {
        const row = buf[4 + i * ROW ..][0..ROW];
        const local_port = std.mem.readInt(u16, row[8..10], .big); // network order in the DWORD's low bytes
        if (std.mem.readInt(u32, row[0..4], .little) == MIB_TCP_STATE_TIME_WAIT and local_port == port) rows += 1;
    }
    return rows;
}

test "TIME_WAIT left by a listener that closed its connections first is not held, so a restart right after serving is never refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const any = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try std.Io.net.IpAddress.listen(&any, io, .{ .mode = .stream, .protocol = .tcp });
    const port = server.socket.address.getPort();
    // The server closes first, the way httpz ends a keep-alive or a request_count cap: that side keeps the
    // TIME_WAIT, on the listening port.
    for (0..4) |_| {
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
        const client = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        const conn = try server.accept(io);
        conn.close(io);
        var rbuf: [16]u8 = undefined;
        var rd = client.reader(io, &rbuf);
        _ = rd.interface.takeByte() catch {}; // EndOfStream: the server's FIN arrived before ours goes out
        client.close(io);
    }
    server.deinit(io);

    // The setup has to have landed, or "not held" proves nothing.
    try std.testing.expect(try timeWaitRows(port) > 0);
    try std.testing.expect(!held(io, port));
}
