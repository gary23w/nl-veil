//! threads.zig — the one way the server starts a thread: `threads.spawn("role", f, args)`.
//!
//! WHY (measured 2026-10-11): Zig 0.16's std.Thread.spawn on Windows passes its stack_size (default 16 MiB) to
//! NtCreateThreadEx as the stack COMMIT, not the reserve. Every thread therefore charged its whole 16 MiB to the
//! machine's commit limit the moment it started, whether or not it ever touched it. The live app sat at 4.7 GB
//! of commit with 160 threads before its first request: 148 stacks x 16 MiB = 2.37 GB, plus httpz's per-worker
//! body buffers (see main.zig). On a box already near its commit limit that pushed Windows to 91% of it.
//!
//! The fix is the commit, not the depth. StackReserve stays `.default` = the executable header's reserve
//! (16 MiB, Zig's default for an executable), so a thread can still grow to the same depth it always could. Only `windows_stack_commit`
//! is committed up front; the rest commits page by page as the guard page is touched, exactly as the main
//! thread's stack always has (its header commit is 4 KiB). LLVM emits __chkstk probes for every Windows frame
//! over a page, so a large frame walks the guard page in order instead of jumping past it.
//!
//! POSIX keeps the std default. A stack there is a fixed mapping that cannot grow past its size, so shrinking it
//! would shrink the real depth. Its pages take RAM only when touched; Linux does count the writable mapping in
//! Committed_AS, which binds only under strict overcommit (vm.overcommit_memory = 2).
//!
//! Each thread is also NAMED ("veil:<role>") on Windows, so a debugger, Process Explorer, and the vitals
//! sampler (worker/vitals.zig) can say which role owns which thread.
const std = @import("std");
const builtin = @import("builtin");

/// What a Windows thread commits at start. Anything deeper commits on demand, up to the 16 MiB reserve.
pub const windows_stack_commit: usize = 256 << 10;

/// The SpawnConfig every thread in this process uses, and the stack size to give std.Io.Threaded's pool.
pub const spawn_config: std.Thread.SpawnConfig = .{
    .stack_size = if (builtin.os.tag == .windows) windows_stack_commit else std.Thread.SpawnConfig.default_stack_size,
};

/// The stack size for `std.Io.Threaded.init(.., .{ .stack_size = threads.io_stack_size })`. Its pool threads go
/// through the same std.Thread.spawn, so the same commit rule applies to them.
pub const io_stack_size: usize = spawn_config.stack_size;

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// std.Thread.spawn with the small-commit config and a thread name. Same errors, same return, same args tuple.
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

test "spawn runs the function with its args and returns its join value" {
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

test "a small-commit thread still reaches deep stacks (the guard page grows it on demand)" {
    // 8 MiB of frames on a thread that committed 256 KiB: proves the reserve, not the commit, bounds depth.
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
