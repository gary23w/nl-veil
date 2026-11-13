//! Keyed writes for the single-value scopes (`Neuron.put`, `Mem.replace`) and how a binary without them is told.
//!
//! Both callers still forget the WHOLE scope before every write, and then store the value with `upsert` under the
//! key `scope` (neuron-db v0.4.0+), or with `observe` on an older binary. The forget is what keeps a read correct
//! when more than one writer touches a scope: another process, an nl-veil build from before keyed writes, or this
//! build's own fallback can each leave an UNKEYED value, which an upsert alone would leave in place and `export`
//! lists first. A per-process record of "this scope holds no unkeyed value" cannot see those writers, so there is
//! no such record: the forget is paid on every write, two spawns, as before the switch.
//!
//! What is remembered is only whether a binary lacks `upsert`, so an older neuron.exe is asked once per process.

const std = @import("std");
const builtin = @import("builtin");

/// What a neuron binary without the keyed commands prints for `upsert` (every build before neuron-db v0.4.0).
pub const UNSUPPORTED = "unknown command: upsert";

var mtx: std.Io.Mutex = .init;
var lacking: std.StringHashMapUnmanaged(void) = .empty;

fn keyInto(buf: []u8, bin: []const u8) ?[]const u8 {
    if (bin.len > buf.len) return null;
    for (bin, 0..) |c, i| buf[i] = if (builtin.os.tag == .windows) (if (c == '\\') '/' else std.ascii.toLower(c)) else c;
    return buf[0..bin.len];
}

/// True when `bin` already answered UNSUPPORTED in this process.
pub fn lacksUpsert(io: std.Io, bin: []const u8) bool {
    var kb: [1024]u8 = undefined;
    const key = keyInto(&kb, bin) orelse return false;
    mtx.lockUncancelable(io);
    defer mtx.unlock(io);
    return lacking.contains(key);
}

/// Remember that `bin` has no `upsert`. Best effort: a record that cannot be allocated means one more ask.
pub fn markLacksUpsert(io: std.Io, bin: []const u8) void {
    var kb: [1024]u8 = undefined;
    const key = keyInto(&kb, bin) orelse return;
    mtx.lockUncancelable(io);
    defer mtx.unlock(io);
    if (lacking.contains(key)) return;
    const pa = std.heap.page_allocator;
    const owned = pa.dupe(u8, key) catch return;
    lacking.put(pa, owned, {}) catch pa.free(owned);
}

test "a binary that lacks upsert is remembered by its path, and no other is" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expect(!lacksUpsert(io, "keyed-test-old.exe"));
    markLacksUpsert(io, "keyed-test-old.exe");
    try std.testing.expect(lacksUpsert(io, "keyed-test-old.exe"));
    try std.testing.expect(!lacksUpsert(io, "keyed-test-new.exe"));
}
