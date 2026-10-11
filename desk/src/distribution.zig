//! MSIX identity and writable state. Portable builds keep their existing paths.
const std = @import("std");
const builtin = @import("builtin");

const win = struct {
    extern "kernel32" fn GetCurrentPackageFamilyName(length: *u32, name: ?[*]u16) callconv(.winapi) i32;
    extern "kernel32" fn SetCurrentDirectoryW(path: [*:0]const u16) callconv(.winapi) i32;
};

pub fn isPackaged() bool {
    if (builtin.os.tag != .windows) return false;
    var length: u32 = 0;
    return win.GetCurrentPackageFamilyName(&length, null) == 122; // ERROR_INSUFFICIENT_BUFFER
}

pub fn packageFamily(gpa: std.mem.Allocator) !?[]u8 {
    if (builtin.os.tag != .windows) return null;
    var name: [256]u16 = undefined;
    var length: u32 = name.len;
    const result = win.GetCurrentPackageFamilyName(&length, &name);
    if (result == 15700) return null; // APPMODEL_ERROR_NO_PACKAGE
    if (result != 0 or length < 2 or length > name.len) return error.PackageIdentityUnavailable;
    return try std.unicode.utf16LeToUtf8Alloc(gpa, name[0 .. length - 1]);
}

pub fn stateRoot(gpa: std.mem.Allocator, local_app_data: []const u8, family: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(local_app_data) or family.len == 0 or
        std.mem.indexOfAny(u8, family, "/\\") != null or std.mem.eql(u8, family, ".."))
        return error.InvalidPackageStatePath;
    return std.fs.path.join(gpa, &.{ local_app_data, "Packages", family, "LocalState" });
}

pub fn setWorkingDirectory(gpa: std.mem.Allocator, path: []const u8) !void {
    if (builtin.os.tag != .windows) return;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(wide);
    if (win.SetCurrentDirectoryW(wide) == 0) return error.PackageWorkingDirectoryUnavailable;
}

test "MSIX state is per-package, absolute, and outside the installation directory" {
    if (builtin.os.tag != .windows) return;
    const a = std.testing.allocator;
    const root = try stateRoot(a, "C:\\Users\\Tester\\AppData\\Local", "Veil_abc123");
    defer a.free(root);
    try std.testing.expectEqualStrings("C:\\Users\\Tester\\AppData\\Local\\Packages\\Veil_abc123\\LocalState", root);
    try std.testing.expectError(error.InvalidPackageStatePath, stateRoot(a, "relative", "Veil_abc123"));
    try std.testing.expectError(error.InvalidPackageStatePath, stateRoot(a, "C:\\Local", "../escape"));
}
