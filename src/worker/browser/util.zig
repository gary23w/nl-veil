//! Small shared helpers for the browser layer.

const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Raw-thread-safe millisecond sleep. std.Io.sleep THROWS on a thread that is not an Io-managed task — e.g. an
/// httpz request-worker thread (the /api/v1/chat/tool path) or the broker's accept thread — and swallowing that
/// error turned every browser wait loop into a busy-spin that never actually waited (so a session/daemon never
/// had time to come up). This uses the OS sleep directly, so it behaves identically on any thread.
pub fn sleepMs(ms: u64) void {
    if (builtin.os.tag == .windows) {
        Sleep(@intCast(@min(ms, @as(u64, std.math.maxInt(u32)))));
    } else {
        // std.Thread.sleep does not exist in this Zig (0.16) — the tree's raw-thread POSIX sleep is a
        // timespec + std.os.linux.nanosleep (see tools.zig watch / run.zig / mcp/client.zig). Split ms
        // into whole seconds + remainder so nsec stays under 1e9.
        const ts = std.posix.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}
