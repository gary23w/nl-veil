//! Per-IP login throttle — MAX_FAILS failed logins from one IP within a sliding window locks it out for LOCK_SECS.

const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

const WINDOW_SECS: i64 = 300;
const MAX_FAILS: u32 = 5;
const LOCK_SECS: i64 = 300;

// EVICTION. fail() is the only path that grows the map, and success() was the only path that ever
// shrank it — so a guesser walking source addresses (or plain background noise from the internet)
// left one heap-allocated key per address FOREVER, whether or not that address was ever locked.
// A record is dead once its window has passed AND its lock has expired: it carries no state the
// throttle would act on, so dropping it is invisible to the outside. Swept on a cadence, plus
// immediately once the map is large enough that a flood is clearly underway.
const SWEEP_EVERY_SECS: i64 = WINDOW_SECS;
const SWEEP_AT_ENTRIES: usize = 4096;

const Rec = struct { fails: u32 = 0, window_start: i64 = 0, locked_until: i64 = 0 };

pub const LoginGuard = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    by_ip: std.StringHashMapUnmanaged(Rec) = .empty,
    last_sweep: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) LoginGuard {
        return .{ .gpa = gpa, .io = io };
    }

    /// Free every duped key and the map itself. In main.zig the guard is a process-lifetime
    /// singleton, so this is for tests and for any future scoped instance.
    pub fn deinit(self: *LoginGuard) void {
        var it = self.by_ip.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.by_ip.deinit(self.gpa);
        self.by_ip = .empty;
    }

    /// Drop records that are neither inside their window nor still locked. Caller holds the lock.
    /// Two passes because removing during iteration invalidates it; the key slice is the map's own
    /// duped memory, so it is freed on the way out.
    fn sweepLocked(self: *LoginGuard, t: i64) void {
        self.last_sweep = t;
        var dead: std.ArrayListUnmanaged([]const u8) = .empty;
        defer dead.deinit(self.gpa);
        var it = self.by_ip.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            if (t - r.window_start > WINDOW_SECS and t >= r.locked_until)
                dead.append(self.gpa, e.key_ptr.*) catch break; // OOM: a partial sweep is still progress
        }
        for (dead.items) |k| if (self.by_ip.fetchRemove(k)) |kv| self.gpa.free(kv.key);
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
        // Before inserting, retire anything already dead — so the map tracks live attackers, not
        // every address that ever mistyped a password.
        // The size trigger is rate-limited to once a second: without that, a flood holding the map
        // at the threshold with LIVE records would make every single failed login pay a full O(n)
        // sweep that frees nothing — turning the defence into its own amplifier.
        if (t - self.last_sweep >= SWEEP_EVERY_SECS or
            (self.by_ip.count() >= SWEEP_AT_ENTRIES and t != self.last_sweep)) self.sweepLocked(t);
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

/// TEST ONLY alias for `deinit`, kept so the tests below read as "hand the map back". LoginGuard
/// dupes every IP key it tracks; tests run on std.testing.allocator, which counts.
fn drainGuardForTest(self: *LoginGuard) void {
    self.deinit();
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

test "sweep retires only records the throttle would never act on again" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = LoginGuard.init(gpa, io);
    defer drainGuardForTest(&g);

    // sweepLocked takes `t`, so the stamps move instead of the clock — but `allowed()` reads the
    // REAL clock, so `t` has to be anchored to it or a "still locked" record reads as ancient
    // history. Margins are wide enough that a second passing mid-test cannot flip either verdict.
    const t: i64 = std.Io.Timestamp.now(io, .real).toSeconds();
    var kb: [16]u8 = undefined;

    const dead = ip4ForTest(203, 0, 113, 20, 40000); // window long past, never locked
    const in_window = ip4ForTest(203, 0, 113, 21, 40000); // still accumulating fails
    const still_locked = ip4ForTest(203, 0, 113, 22, 40000); // window past BUT serving a lock
    const just_expired = ip4ForTest(203, 0, 113, 23, 40000); // lock ended exactly now
    for ([_]IpAddress{ dead, in_window, still_locked, just_expired }) |a| g.fail(a);
    try std.testing.expectEqual(@as(usize, 4), g.by_ip.count());

    g.by_ip.getPtr(LoginGuard.ipKey(dead, &kb)).?.* = .{ .fails = 2, .window_start = t - WINDOW_SECS - 1, .locked_until = 0 };
    g.by_ip.getPtr(LoginGuard.ipKey(in_window, &kb)).?.* = .{ .fails = 2, .window_start = t - WINDOW_SECS, .locked_until = 0 };
    g.by_ip.getPtr(LoginGuard.ipKey(still_locked, &kb)).?.* = .{ .fails = MAX_FAILS, .window_start = t - WINDOW_SECS - 1, .locked_until = t + 3600 };
    g.by_ip.getPtr(LoginGuard.ipKey(just_expired, &kb)).?.* = .{ .fails = MAX_FAILS, .window_start = t - WINDOW_SECS - 1, .locked_until = t };

    g.mu.lockUncancelable(io);
    g.sweepLocked(t);
    g.mu.unlock(io);

    // Gone: nothing about it could change a future verdict.
    try std.testing.expect(g.by_ip.get(LoginGuard.ipKey(dead, &kb)) == null);
    // Kept: its window is still open (the boundary is `>`, so exactly WINDOW_SECS old survives), so
    // its banked fails still count toward a lock.
    try std.testing.expect(g.by_ip.get(LoginGuard.ipKey(in_window, &kb)) != null);
    // Kept: dropping a record mid-lock would HAND THE ATTACKER a clean slate — the one eviction bug
    // that would matter.
    try std.testing.expect(g.by_ip.get(LoginGuard.ipKey(still_locked, &kb)) != null);
    try std.testing.expect(!g.allowed(still_locked));
    // Gone: `allowed` is `now >= locked_until`, so a lock ending exactly now is already lifted.
    try std.testing.expect(g.by_ip.get(LoginGuard.ipKey(just_expired, &kb)) == null);
    // four went in, the two retired ones are gone, and nothing else was touched
    try std.testing.expectEqual(@as(usize, 2), g.by_ip.count());
}

test "the map stops growing: a walk across addresses is retired on the sweep cadence" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = LoginGuard.init(gpa, io);
    defer drainGuardForTest(&g);

    // 300 addresses each mistyping a password once — the shape of internet background noise, and of
    // a distributed guesser spreading its attempts thin enough never to trip a per-IP lock.
    var i: u16 = 0;
    while (i < 300) : (i += 1) g.fail(ip4ForTest(198, 51, 100, @intCast(i % 256), 40000 + i));
    const walked = g.by_ip.count();
    try std.testing.expect(walked > 100); // they really are separate buckets

    // Age every one of them past its window, then let the cadence fire on the next failure.
    var it = g.by_ip.valueIterator();
    while (it.next()) |r| r.window_start -= WINDOW_SECS + 1;
    g.last_sweep = 0; // force the cadence branch (t - 0 >= SWEEP_EVERY_SECS)
    g.fail(ip4ForTest(203, 0, 113, 99, 40000));

    // Before this fix the count only ever climbed; now the walk is retired and only the live
    // attempt remains.
    try std.testing.expectEqual(@as(usize, 1), g.by_ip.count());
}
