//! NOTE: local patch to vendored httpz (nl-veil, 2026-10-11). Zig 0.16's std.Thread.spawn hands its stack_size
//! (default 16 MiB) to NtCreateThreadEx as the stack COMMIT on Windows, so the 128 blocking-mode workers charged
//! 2 GiB of commit before serving a request. Commit 256 KiB instead; the stack still grows on demand to the
//! executable's 16 MiB reserve (StackReserve stays the header default). POSIX keeps the std default. Mirrors
//! nl-veil's src/threads.zig, which every non-httpz thread in the app goes through.
const std = @import("std");
const builtin = @import("builtin");

pub const config: std.Thread.SpawnConfig = .{
    .stack_size = if (builtin.os.tag == .windows) 256 << 10 else std.Thread.SpawnConfig.default_stack_size,
};

extern "kernel32" fn SetThreadDescription(thread: std.os.windows.HANDLE, desc: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) std.os.windows.HANDLE;

/// Name the calling thread (Windows only, best effort) so the app's vitals line can count httpz workers.
pub fn nameCurrent(comptime name: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const wide = comptime blk: {
        var w: [name.len:0]u16 = undefined;
        for (name, 0..) |c, i| w[i] = c;
        break :blk w;
    };
    _ = SetThreadDescription(GetCurrentThread(), &wide);
}
