//! secrets.zig — at-rest protection for the chat API key. On Windows the key is sealed with DPAPI
//! (CryptProtectData, current-user scope) so the blob on disk is useless off this account/machine; on
//! POSIX it falls back to a plain file inside the (user-private) data dir, mirroring how the server
//! already keeps `.desktop_key` there. The key NEVER goes into a repo-tracked file — everything under
//! <data>/ is untracked run state. Runs on the CHAT thread (it owns io for all chat-side storage).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = @import("log.zig");

const FILE_WIN = "chat_key.bin"; // DPAPI blob
const FILE_POSIX = "chat_key"; // plain (dir is user-private, same trust as .desktop_key)

const win = struct {
    const DATA_BLOB = extern struct { cbData: u32, pbData: ?[*]u8 };
    const CRYPTPROTECT_UI_FORBIDDEN: u32 = 0x1;
    extern "crypt32" fn CryptProtectData(pDataIn: *const DATA_BLOB, szDataDescr: ?[*:0]const u16, pOptionalEntropy: ?*const DATA_BLOB, pvReserved: ?*anyopaque, pPromptStruct: ?*anyopaque, dwFlags: u32, pDataOut: *DATA_BLOB) callconv(.winapi) i32;
    extern "crypt32" fn CryptUnprotectData(pDataIn: *const DATA_BLOB, ppszDataDescr: ?*?[*:0]u16, pOptionalEntropy: ?*const DATA_BLOB, pvReserved: ?*anyopaque, pPromptStruct: ?*anyopaque, dwFlags: u32, pDataOut: *DATA_BLOB) callconv(.winapi) i32;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
};

fn path(gpa: std.mem.Allocator, dir: []const u8) ?[]u8 {
    const name = if (builtin.os.tag == .windows) FILE_WIN else FILE_POSIX;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch null;
}

/// Persist `key` under `dir` (the .veil-desk sidecar dir). An empty key removes the stored secret.
pub fn save(io: Io, gpa: std.mem.Allocator, dir: []const u8, key: []const u8) bool {
    log.trace("secrets.save dir={s} key_len={d}", .{ dir, key.len });
    const p = path(gpa, dir) orelse return false;
    defer gpa.free(p);
    if (key.len == 0) {
        Io.Dir.cwd().deleteFile(io, p) catch {};
        return true;
    }
    if (builtin.os.tag == .windows) {
        var in_blob: win.DATA_BLOB = .{ .cbData = @intCast(key.len), .pbData = @constCast(key.ptr) };
        var out_blob: win.DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (win.CryptProtectData(&in_blob, null, null, null, null, win.CRYPTPROTECT_UI_FORBIDDEN, &out_blob) == 0) {
            log.err("secrets: CryptProtectData failed", .{});
            return false;
        }
        defer _ = win.LocalFree(out_blob.pbData);
        const sealed = out_blob.pbData.?[0..out_blob.cbData];
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = sealed }) catch {
            log.err("secrets: could not write {s}", .{p});
            return false;
        };
        return true;
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = key }) catch return false;
    return true;
}

/// Load the stored key into `out`; returns its length (0 = none stored / unreadable).
pub fn load(io: Io, gpa: std.mem.Allocator, dir: []const u8, out: []u8) usize {
    log.trace("secrets.load dir={s}", .{dir});
    const p = path(gpa, dir) orelse return 0;
    defer gpa.free(p);
    const data = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 10)) catch return 0;
    defer gpa.free(data);
    if (data.len == 0) return 0;
    if (builtin.os.tag == .windows) {
        var in_blob: win.DATA_BLOB = .{ .cbData = @intCast(data.len), .pbData = data.ptr };
        var out_blob: win.DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (win.CryptUnprotectData(&in_blob, null, null, null, null, win.CRYPTPROTECT_UI_FORBIDDEN, &out_blob) == 0) {
            log.warn("secrets: CryptUnprotectData failed (blob from another account?)", .{});
            return 0;
        }
        defer _ = win.LocalFree(out_blob.pbData);
        const plain = out_blob.pbData.?[0..out_blob.cbData];
        const n = @min(plain.len, out.len);
        @memcpy(out[0..n], plain[0..n]);
        return n;
    }
    const trimmed = std.mem.trim(u8, data, " \r\n\t");
    const n = @min(trimmed.len, out.len);
    @memcpy(out[0..n], trimmed[0..n]);
    return n;
}

test "secrets round-trip (native store)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "zig-secrets-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.testing.expect(save(io, std.testing.allocator, dir, "sk-test-1234"));
    var buf: [64]u8 = undefined;
    const n = load(io, std.testing.allocator, dir, &buf);
    try std.testing.expectEqualStrings("sk-test-1234", buf[0..n]);
    // empty key removes the secret
    try std.testing.expect(save(io, std.testing.allocator, dir, ""));
    try std.testing.expectEqual(@as(usize, 0), load(io, std.testing.allocator, dir, &buf));
}
