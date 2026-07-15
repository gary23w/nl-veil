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
