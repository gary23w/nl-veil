//! lan.zig — which addresses this machine is reachable at.
//!
//! The server binds every interface by default, so the useful thing to tell somebody at startup is a
//! URL they can type on another device. "http://<this machine>:8787" is not that.
//!
//! This lives in its own file rather than in main.zig for one practical reason: src/tests.zig does not
//! import main.zig, so a test written there never runs. That is not hypothetical — the first version of
//! this parser shipped with a test beside it that was silently collected by nothing.

const std = @import("std");
const builtin = @import("builtin");

/// Four dot-separated decimal octets, each 0-255. Hand-rolled because std.net is gone in Zig 0.16 and
/// std.Io.net offers no parser. It only has to reject the other tokens in `ipconfig` / `ifconfig`
/// output; masks are filtered by the caller, since 255.255.255.0 is a perfectly well-formed address.
pub fn looksLikeIpv4(s: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        parts += 1;
        if (parts > 4 or p.len == 0 or p.len > 3) return false;
        for (p) |c| if (c < '0' or c > '9') return false;
        if ((std.fmt.parseInt(u16, p, 10) catch return false) > 255) return false;
    }
    return parts == 4;
}

/// True for an address nobody can usefully open from another machine.
pub fn isUninteresting(ip: []const u8) bool {
    return std.mem.startsWith(u8, ip, "127.") or // loopback
        std.mem.startsWith(u8, ip, "169.254.") or // link-local autoconfiguration
        std.mem.startsWith(u8, ip, "0.") or // wildcard
        std.mem.startsWith(u8, ip, "255."); // a mask, never a host
}

/// Extract host addresses from the output of the per-OS command below, space-joined into `out`.
///
/// LINE-aware, not token-aware, and that distinction is the whole function: tokenising `ipconfig`
/// wholesale also picks up the Default Gateway and the subnet mask. Both are well-formed IPv4 and
/// neither is an address this machine answers on — the first attempt happily advertised the router.
pub fn parseAddresses(stdout: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var seen_any = false;
    var lines = std.mem.splitAny(u8, stdout, "\r\n");
    while (lines.next()) |line| {
        const relevant = switch (builtin.os.tag) {
            .windows => std.mem.indexOf(u8, line, "IPv4") != null,
            .macos => std.mem.indexOf(u8, line, "inet ") != null, // the trailing space excludes inet6
            else => true, // `hostname -I` prints addresses and nothing else
        };
        if (!relevant) continue;

        var toks = std.mem.tokenizeAny(u8, line, " \t:");
        while (toks.next()) |tok| {
            if (!looksLikeIpv4(tok) or isUninteresting(tok)) continue;
            var dup = false;
            var have = std.mem.splitScalar(u8, out[0..n], ' ');
            while (have.next()) |h| {
                if (std.mem.eql(u8, h, tok)) dup = true;
            }
            if (dup) continue;
            if (n + tok.len + 1 > out.len) return out[0..n];
            if (seen_any) {
                out[n] = ' ';
                n += 1;
            }
            @memcpy(out[n..][0..tok.len], tok);
            n += tok.len;
            seen_any = true;
            break; // one address per line; the rest of a Windows line is padding
        }
    }
    return out[0..n];
}

/// Run the per-OS command and parse it. Shelling out is deliberate: Zig 0.16's std.Io exposes no
/// interface enumeration and no getsockname, so the alternative is per-OS FFI (GetAdaptersAddresses /
/// getifaddrs) for a string needed exactly once at startup.
pub fn addresses(gpa: std.mem.Allocator, io: std.Io, out: []u8) []const u8 {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{"ipconfig"},
        .macos => &.{"ifconfig"},
        else => &.{ "hostname", "-I" },
    };
    const r = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(64 << 10), .stderr_limit = .limited(4 << 10) }) catch return "";
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return parseAddresses(r.stdout, out);
}

test "looksLikeIpv4 accepts addresses and rejects everything else in the output" {
    const t = std.testing;
    try t.expect(looksLikeIpv4("192.168.1.42"));
    try t.expect(looksLikeIpv4("10.0.0.1"));
    try t.expect(looksLikeIpv4("255.255.255.0")); // well-formed; isUninteresting rejects it, not this
    try t.expect(!looksLikeIpv4("192.168.1"));
    try t.expect(!looksLikeIpv4("192.168.1.256"));
    try t.expect(!looksLikeIpv4("Ethernet"));
    try t.expect(!looksLikeIpv4("fe80::1"));
    try t.expect(!looksLikeIpv4(""));
}

test "parseAddresses keeps host addresses and drops the gateway and mask" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const sample =
        \\Windows IP Configuration
        \\
        \\Ethernet adapter Ethernet:
        \\   IPv4 Address. . . . . . . . . . . : 192.160.0.115
        \\   Subnet Mask . . . . . . . . . . . : 255.255.255.0
        \\   Default Gateway . . . . . . . . . : 192.160.0.1
        \\
        \\Ethernet adapter VirtualBox Host-Only Network:
        \\   IPv4 Address. . . . . . . . . . . : 192.168.56.1
        \\   Subnet Mask . . . . . . . . . . . : 255.255.255.0
        \\
        \\Tunnel adapter Loopback:
        \\   IPv4 Address. . . . . . . . . . . : 127.0.0.1
        \\
    ;
    var buf: [256]u8 = undefined;
    const got = parseAddresses(sample, &buf);
    // The gateway (192.160.0.1) shares a line with nothing else and is NOT an "IPv4" line — this is
    // the regression that shipped once: it was advertised as a way to reach the veil.
    try std.testing.expectEqualStrings("192.160.0.115 192.168.56.1", got);
}

test "parseAddresses de-duplicates and survives empty input" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", parseAddresses("", &buf));
    const dupes = "   IPv4 Address. . . : 10.0.0.5\r\n   IPv4 Address. . . : 10.0.0.5\r\n";
    try std.testing.expectEqualStrings("10.0.0.5", parseAddresses(dupes, &buf));
}
