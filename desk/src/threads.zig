//! threads.zig (desk) — how the desk starts a thread: `vthread.spawn("role", f, args)`.
//!
//! TWIN FILE: the desk twin of src/threads.zig. The desk is a module of its own and cannot import the server's
//! copy, so this one carries the same body: everything below this //! header must stay identical to
//! src/threads.zig (`scripts/check.ps1 -Scan` and `scripts/check.sh --scan` compare them). The WHY lives in
//! that file's header: on Windows, Zig 0.16's std.Thread.spawn commits its whole stack_size (16 MiB by
//! default) up front; this commits 256 KiB and lets the stack grow on demand to the same 16 MiB reserve, and
//! names each thread "veil:<role>".
const std = @import("std");
const builtin = @import("builtin");

/// What a Windows thread commits at start. Anything deeper commits on demand, up to the 16 MiB reserve.
pub const windows_stack_commit: usize = 256 << 10;

/// The SpawnConfig every thread started through `spawn` uses.
pub const spawn_config: std.Thread.SpawnConfig = .{
    .stack_size = if (builtin.os.tag == .windows) windows_stack_commit else std.Thread.SpawnConfig.default_stack_size,
};

/// The stack size for `std.Io.Threaded.init(.., .{ .stack_size = vthread.io_stack_size })`: its pool threads go
/// through the same std.Thread.spawn, so the same commit rule applies to them.
pub const io_stack_size: usize = spawn_config.stack_size;

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// std.Thread.spawn with the small-commit config, and the new thread named "veil:<role>". Same errors, same
/// return value, same args tuple as std.Thread.spawn.
pub fn spawn(comptime role: []const u8, comptime f: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
    const Args = @TypeOf(args);
    const S = struct {
        fn run(a: Args) ReturnOf(f) {
            nameCurrent("veil:" ++ role);
            return @call(.auto, f, a);
        }
    };
    return std.Thread.spawn(spawn_config, S.run, .{args});
}

extern "kernel32" fn SetThreadDescription(thread: std.os.windows.HANDLE, desc: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) std.os.windows.HANDLE;

/// Name the calling thread. Windows only (SetThreadDescription, Windows 10 1607+); best effort, never fails.
pub fn nameCurrent(comptime name: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const wide = comptime blk: {
        var w: [name.len:0]u16 = undefined;
        for (name, 0..) |c, i| w[i] = c;
        break :blk w;
    };
    _ = SetThreadDescription(GetCurrentThread(), &wide);
}

test "spawn runs the function with its args and joins" {
    const R = struct {
        fn add(a: u32, b: u32, out: *u32) void {
            out.* = a + b;
        }
    };
    var got: u32 = 0;
    const t = try spawn("test", R.add, .{ 2, 3, &got });
    t.join();
    try std.testing.expectEqual(@as(u32, 5), got);
}

test "a small-commit thread still reaches a deep stack (the guard page grows it on demand)" {
    // 8 MiB of frames on a thread that committed 256 KiB on Windows: the reserve, not the commit, bounds depth.
    const R = struct {
        fn recurse(depth: usize) usize {
            var frame: [16 * 1024]u8 = undefined; // 16 KiB per frame, written and read so it is really used
            @memset(&frame, @truncate(depth));
            const below = if (depth > 0) recurse(depth - 1) else 0;
            return below + 1 + (frame[depth % frame.len] & 0); // keeps the frame live across the call
        }
        fn run(out: *usize) void {
            out.* = recurse(511); // 512 frames x 16 KiB = 8 MiB
        }
    };
    var frames: usize = 0;
    const t = try spawn("test-deep", R.run, .{&frames});
    t.join();
    try std.testing.expectEqual(@as(usize, 512), frames);
}

test "spawn_config commits small on Windows and keeps the std default elsewhere" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(windows_stack_commit, spawn_config.stack_size);
    } else {
        try std.testing.expectEqual(std.Thread.SpawnConfig.default_stack_size, spawn_config.stack_size);
    }
    try std.testing.expectEqual(spawn_config.stack_size, io_stack_size);
}
