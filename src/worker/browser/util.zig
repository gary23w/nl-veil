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
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
}
