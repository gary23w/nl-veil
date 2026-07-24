//! Per-IP login throttle — MAX_FAILS failed logins from one IP within a sliding window locks it out for LOCK_SECS.

const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

const WINDOW_SECS: i64 = 300;
const MAX_FAILS: u32 = 5;
const LOCK_SECS: i64 = 300;

const Rec = struct { fails: u32 = 0, window_start: i64 = 0, locked_until: i64 = 0 };

pub const LoginGuard = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    by_ip: std.StringHashMapUnmanaged(Rec) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) LoginGuard {
        return .{ .gpa = gpa, .io = io };
    }

    fn ipKey(addr: IpAddress, out: *[16]u8) []const u8 {
        switch (addr) {
            .ip4 => |a| {
                @memcpy(out[0..4], &a.bytes);
                return out[0..4];
            },
            .ip6 => |a| {
                @memcpy(out[0..16], &a.bytes);
                return out[0..16];
            },
        }
    }

    fn now(self: *LoginGuard) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    pub fn allowed(self: *LoginGuard, addr: IpAddress) bool {
        var kb: [16]u8 = undefined;
        const k = ipKey(addr, &kb);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const r = self.by_ip.get(k) orelse return true;
        return self.now() >= r.locked_until;
    }

    pub fn fail(self: *LoginGuard, addr: IpAddress) void {
        var kb: [16]u8 = undefined;
        const k = ipKey(addr, &kb);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const t = self.now();
        const gop = self.by_ip.getOrPut(self.gpa, k) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, k) catch {
                _ = self.by_ip.remove(k);
                return;
            };
            gop.value_ptr.* = .{ .window_start = t };
        }
        const r = gop.value_ptr;
        if (t - r.window_start > WINDOW_SECS) {
            r.window_start = t;
            r.fails = 0;
        }
        r.fails += 1;
        if (r.fails >= MAX_FAILS) r.locked_until = t + LOCK_SECS;
    }

    pub fn success(self: *LoginGuard, addr: IpAddress) void {
        var kb: [16]u8 = undefined;
        const k = ipKey(addr, &kb);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.by_ip.fetchRemove(k)) |kv| self.gpa.free(kv.key);
    }
};

// This is the only thing standing between the login endpoint and an unlimited password-guessing rate, so
// the tests below pin the ACTUAL tuning constants and the four behaviours that make the throttle a throttle:
// the count that trips it, the span the lock covers, the independence of one address from another, and the
// clearing effect of a real login. Nothing here sleeps — a 300 s lock is not a unit test, and the expiry
// rules are plain arithmetic over a stored timestamp, so the stamps are moved instead of the clock.

/// TEST ONLY. LoginGuard dupes every IP key it tracks and has no deinit — in main.zig it is a
/// process-lifetime singleton, and success() is what normally frees an entry. Tests run on
/// std.testing.allocator, which counts, so they hand the map back themselves.
fn drainGuardForTest(self: *LoginGuard) void {
    var it = self.by_ip.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.by_ip.deinit(self.gpa);
}

/// TEST ONLY. The documentation-range addresses (RFC 5737) these tests attack from.
fn ip4ForTest(a: u8, b: u8, c: u8, d: u8, port: u16) IpAddress {
    return .{ .ip4 = .{ .bytes = .{ a, b, c, d }, .port = port } };
}

test "throttle trips at MAX_FAILS and the lock it stamps runs LOCK_SECS" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = LoginGuard.init(gpa, io);
    defer drainGuardForTest(&g);

    // The tuning this whole file is written against. If these move the assertions below move with them —
    // and a silent widening of the limit (the failure that matters) shows up right here.
    try std.testing.expectEqual(@as(u32, 5), MAX_FAILS);
    try std.testing.expectEqual(@as(i64, 300), WINDOW_SECS);
    try std.testing.expectEqual(@as(i64, 300), LOCK_SECS);

    const ip = ip4ForTest(203, 0, 113, 7, 51000);
    try std.testing.expect(g.allowed(ip)); // never seen: served

    var i: u32 = 0;
    while (i < MAX_FAILS - 1) : (i += 1) {
        g.fail(ip);
        try std.testing.expect(g.allowed(ip)); // 1..4 wrong passwords still get a login form
    }

    const t = std.Io.Timestamp.now(io, .real).toSeconds();
    g.fail(ip); // the MAX_FAILS'th
    try std.testing.expect(!g.allowed(ip));

    var kb: [16]u8 = undefined;
    const rec = g.by_ip.get(LoginGuard.ipKey(ip, &kb)).?;
    try std.testing.expectEqual(MAX_FAILS, rec.fails);
    // Stamped LOCK_SECS out from the moment of the fail; the clock gets a couple of seconds of slack.
    try std.testing.expect(rec.locked_until >= t + LOCK_SECS);
    try std.testing.expect(rec.locked_until <= t + LOCK_SECS + 2);
}

test "the lockout is time-boxed: once locked_until has passed the same IP is served again" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = LoginGuard.init(gpa, io);
    defer drainGuardForTest(&g);

    const ip = ip4ForTest(203, 0, 113, 8, 51000);
    var i: u32 = 0;
    while (i < MAX_FAILS) : (i += 1) g.fail(ip);
    try std.testing.expect(!g.allowed(ip));

    // allowed() is `now() >= locked_until`, so rewinding the stamp is the same experiment as waiting out
    // the lock — and it is the only one that finishes in a test. Offsets are wide enough that a clock tick
    // between the write and the read cannot flip an answer.
    var kb: [16]u8 = undefined;
    const rec = g.by_ip.getPtr(LoginGuard.ipKey(ip, &kb)).?;
    const t = std.Io.Timestamp.now(io, .real).toSeconds();

    rec.locked_until = t + LOCK_SECS; // a full lock still ahead
    try std.testing.expect(!g.allowed(ip));
    rec.locked_until = t + 60; // mid-lock
    try std.testing.expect(!g.allowed(ip));
    rec.locked_until = t; // the boundary itself is open (>=), and time only moves forward
    try std.testing.expect(g.allowed(ip));
    rec.locked_until = t - 1; // expired
    try std.testing.expect(g.allowed(ip));

    // Expiry lifts the lock; it does not erase the record, and the next fail is still counted.
    try std.testing.expectEqual(@as(usize, 1), g.by_ip.count());
}

test "buckets are per-address: a neighbour, a v6 peer and a new source port are judged separately" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = LoginGuard.init(gpa, io);
    defer drainGuardForTest(&g);

    const bad = ip4ForTest(198, 51, 100, 10, 40000);
    const neighbour = ip4ForTest(198, 51, 100, 11, 40000);
    // Same trailing four bytes as `bad`, but a 16-byte identity — it must not inherit the lock.
    const v6: IpAddress = .{ .ip6 = .{ .port = 40000, .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 198, 51, 100, 10 } } };

    var i: u32 = 0;
    while (i < MAX_FAILS) : (i += 1) g.fail(bad);
    try std.testing.expect(!g.allowed(bad));
    try std.testing.expect(g.allowed(neighbour)); // one bad tenant must not lock out the building
    try std.testing.expect(g.allowed(v6));

    // Conversely, the source PORT is not part of the identity: reconnecting is the same attacker, and a
    // fresh ephemeral port per attempt is the cheapest way there would be to walk around the throttle.
    try std.testing.expect(!g.allowed(ip4ForTest(198, 51, 100, 10, 40001)));
    g.fail(ip4ForTest(198, 51, 100, 10, 40002));
    try std.testing.expectEqual(@as(usize, 1), g.by_ip.count()); // …and it lands in the same bucket

    // The v6 peer keeps its own count all the way to its own lock, without touching v4's.
    i = 0;
    while (i < MAX_FAILS) : (i += 1) g.fail(v6);
    try std.testing.expect(!g.allowed(v6));
    try std.testing.expect(g.allowed(neighbour));
}

test "a successful login clears the whole counter, not just the lock" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = LoginGuard.init(gpa, io);
    defer drainGuardForTest(&g);

    const ip = ip4ForTest(192, 0, 2, 55, 1234);
    var i: u32 = 0;
    while (i < MAX_FAILS - 1) : (i += 1) g.fail(ip); // 4 banked, one short of the lock
    g.success(ip);
    try std.testing.expectEqual(@as(usize, 0), g.by_ip.count()); // the entry is dropped outright

    // If success had only cleared the LOCK and left the count, the very next fail would trip the limit.
    i = 0;
    while (i < MAX_FAILS - 1) : (i += 1) {
        g.fail(ip);
        try std.testing.expect(g.allowed(ip));
    }
    g.fail(ip);
    try std.testing.expect(!g.allowed(ip));

    g.success(ip); // succeeding while locked lifts the lock too
    try std.testing.expect(g.allowed(ip));
    try std.testing.expectEqual(@as(usize, 0), g.by_ip.count());

    g.success(ip); // clearing an address that was never tracked is a no-op, not a double free
    try std.testing.expectEqual(@as(usize, 0), g.by_ip.count());
}

test "the window slides: fails older than WINDOW_SECS start a fresh count instead of locking" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = LoginGuard.init(gpa, io);
    defer drainGuardForTest(&g);

    const ip = ip4ForTest(192, 0, 2, 99, 2222);
    var kb: [16]u8 = undefined;
    const k = LoginGuard.ipKey(ip, &kb);

    var i: u32 = 0;
    while (i < MAX_FAILS - 1) : (i += 1) g.fail(ip); // 4 banked, one short of the lock
    try std.testing.expectEqual(MAX_FAILS - 1, g.by_ip.get(k).?.fails);

    // Age the window past its end. Rewinding window_start is equivalent to waiting: the reset test is
    // `t - window_start > WINDOW_SECS`, and a clock that ticks forward mid-test only pushes it further past,
    // so +1 here is exact rather than flaky.
    g.by_ip.getPtr(k).?.window_start = std.Io.Timestamp.now(io, .real).toSeconds() - (WINDOW_SECS + 1);
    g.fail(ip);
    try std.testing.expectEqual(@as(u32, 1), g.by_ip.get(k).?.fails); // counted as the FIRST fail of a new window
    try std.testing.expect(g.allowed(ip)); // a slow guesser never accumulates a lock

    // The other direction: inside the window the fails DO add up. Backdating to just under the edge (the
    // slack absorbs a tick without crossing WINDOW_SECS) leaves the count standing, so four more lock it.
    g.by_ip.getPtr(k).?.window_start = std.Io.Timestamp.now(io, .real).toSeconds() - (WINDOW_SECS - 5);
    i = 0;
    while (i < MAX_FAILS - 2) : (i += 1) {
        g.fail(ip);
        try std.testing.expect(g.allowed(ip));
    }
    g.fail(ip);
    try std.testing.expect(!g.allowed(ip));
    try std.testing.expectEqual(MAX_FAILS, g.by_ip.get(k).?.fails);
}
