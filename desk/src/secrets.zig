//! secrets.zig — at-rest storage for the chat API key and the GitHub PAT. This is a LOCAL, single-user,
//! login-gated app, so secrets are kept as PLAINTEXT inside the (user-private, git-untracked) <data>/ dir —
//! the trust boundary is the OS login, not per-secret encryption. Storing them plaintext-local is deliberate:
//! it lets the veil READ its own GitHub token (to curl / set a remote URL) instead of it being locked in an
//! opaque blob it can't use. Older builds DPAPI-sealed these files; `loadAt` transparently unseals such a
//! legacy blob ONCE and rewrites it as plaintext (the auto-unseal migration). Nothing here ever reaches a
//! repo-tracked file. Runs on the CHAT thread (it owns io for all chat-side storage).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = @import("log.zig");

const FILE_WIN = "chat_key.bin"; // plaintext now (legacy DPAPI blobs auto-migrate on load); name kept so old files still resolve
const FILE_POSIX = "chat_key"; // plain (dir is user-private, same trust as .desktop_key)
const PAT_WIN = "github_pat.bin"; // the GitHub PAT — plaintext-local, same as the chat key
const PAT_POSIX = "github_pat";

const win = struct {
    const DATA_BLOB = extern struct { cbData: u32, pbData: ?[*]u8 };
    const CRYPTPROTECT_UI_FORBIDDEN: u32 = 0x1;
    // Only UNSEAL survives — used once to migrate a legacy sealed blob to plaintext. We never seal again.
    extern "crypt32" fn CryptUnprotectData(pDataIn: *const DATA_BLOB, ppszDataDescr: ?*?[*:0]u16, pOptionalEntropy: ?*const DATA_BLOB, pvReserved: ?*anyopaque, pPromptStruct: ?*anyopaque, dwFlags: u32, pDataOut: *DATA_BLOB) callconv(.winapi) i32;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
};

fn pathFor(gpa: std.mem.Allocator, dir: []const u8, win_name: []const u8, posix_name: []const u8) ?[]u8 {
    const name = if (builtin.os.tag == .windows) win_name else posix_name;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch null;
}

fn path(gpa: std.mem.Allocator, dir: []const u8) ?[]u8 {
    return pathFor(gpa, dir, FILE_WIN, FILE_POSIX);
}

/// Persist the GitHub PAT under `dir` as plaintext-local. Empty removes it.
pub fn savePat(io: Io, gpa: std.mem.Allocator, dir: []const u8, pat: []const u8) bool {
    const p = pathFor(gpa, dir, PAT_WIN, PAT_POSIX) orelse return false;
    defer gpa.free(p);
    return saveAt(io, gpa, p, pat);
}

/// Load the GitHub PAT into `out`; returns its length (0 = none / unreadable). Legacy sealed blobs auto-migrate.
pub fn loadPat(io: Io, gpa: std.mem.Allocator, dir: []const u8, out: []u8) usize {
    const p = pathFor(gpa, dir, PAT_WIN, PAT_POSIX) orelse return 0;
    defer gpa.free(p);
    return loadAt(io, gpa, p, out);
}

/// Persist `key` under `dir` (the .veil-desk sidecar dir) as plaintext-local. An empty key removes it.
pub fn save(io: Io, gpa: std.mem.Allocator, dir: []const u8, key: []const u8) bool {
    log.trace("secrets.save dir={s} key_len={d}", .{ dir, key.len });
    const p = path(gpa, dir) orelse return false;
    defer gpa.free(p);
    return saveAt(io, gpa, p, key);
}

/// Write `key` to `p` as plaintext in the user-private (untracked) data dir. An empty key deletes the file.
/// LOCAL, login-gated app — the OS account is the trust boundary; no per-secret sealing (see the module doc).
fn saveAt(io: Io, gpa: std.mem.Allocator, p: []const u8, key: []const u8) bool {
    _ = gpa;
    if (key.len == 0) {
        Io.Dir.cwd().deleteFile(io, p) catch {};
        return true;
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = key }) catch {
        log.err("secrets: could not write {s}", .{p});
        return false;
    };
    return true;
}

/// Load the stored key into `out`; returns its length (0 = none stored / unreadable).
pub fn load(io: Io, gpa: std.mem.Allocator, dir: []const u8, out: []u8) usize {
    log.trace("secrets.load dir={s}", .{dir});
    const p = path(gpa, dir) orelse return 0;
    defer gpa.free(p);
    return loadAt(io, gpa, p, out);
}

// ---- PER-PROVIDER keys ---------------------------------------------------------------------------------
// Each cloud/BYOK provider (and the custom URL) keeps its OWN at-rest key, so selecting DeepSeek and saving a
// key never overwrites (or gets mismatched with) the OpenAI/Anthropic/… key. The `slug` is the provider's
// stable catalog id (e.g. "deepseek", "workers-ai", "custom") — filesystem-safe by construction.

/// `<dir>/chat_key_<slug>[.bin]` — the per-provider key file. null only on alloc failure.
fn pathForSlug(gpa: std.mem.Allocator, dir: []const u8, slug: []const u8) ?[]u8 {
    const ext = if (builtin.os.tag == .windows) ".bin" else "";
    return std.fmt.allocPrint(gpa, "{s}/chat_key_{s}{s}", .{ dir, slug, ext }) catch null;
}

/// Persist `key` for provider `slug` as plaintext-local. Empty removes just that provider's key.
pub fn saveFor(io: Io, gpa: std.mem.Allocator, dir: []const u8, slug: []const u8, key: []const u8) bool {
    log.trace("secrets.saveFor slug={s} key_len={d}", .{ slug, key.len });
    const p = pathForSlug(gpa, dir, slug) orelse return false;
    defer gpa.free(p);
    return saveAt(io, gpa, p, key);
}

/// Load provider `slug`'s key into `out`; returns its length (0 = none stored for this provider).
pub fn loadFor(io: Io, gpa: std.mem.Allocator, dir: []const u8, slug: []const u8, out: []u8) usize {
    const p = pathForSlug(gpa, dir, slug) orelse return 0;
    defer gpa.free(p);
    return loadAt(io, gpa, p, out);
}

/// ONE-TIME UPGRADE: an older build stored a SINGLE global key (`chat_key`) shared across every provider.
/// Move it to `slug` — the provider it was actually being used for — and delete the legacy file, so the
/// upgrading user keeps their key for the current provider while every OTHER provider correctly starts empty
/// (the old shared-key mismatch is gone). Returns the migrated length in `out` (0 = nothing to migrate).
pub fn migrateLegacy(io: Io, gpa: std.mem.Allocator, dir: []const u8, slug: []const u8, out: []u8) usize {
    const legacy = path(gpa, dir) orelse return 0;
    defer gpa.free(legacy);
    const n = loadAt(io, gpa, legacy, out);
    if (n == 0) return 0;
    _ = saveFor(io, gpa, dir, slug, out[0..n]);
    Io.Dir.cwd().deleteFile(io, legacy) catch {};
    log.info("secrets: migrated the legacy shared chat key to provider '{s}'", .{slug});
    return n;
}

/// Read the plaintext secret from `p`. AUTO-UNSEAL MIGRATION: a file written by an older build is a DPAPI blob;
/// on Windows we try to unseal it ONCE and, on success, rewrite it as plaintext so at-rest is plaintext-local
/// from here on. A plaintext file fails the unseal (DPAPI blobs are structured) and falls through unchanged.
fn loadAt(io: Io, gpa: std.mem.Allocator, p: []const u8, out: []u8) usize {
    const data = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 10)) catch return 0;
    defer gpa.free(data);
    if (data.len == 0) return 0;
    if (builtin.os.tag == .windows) {
        var in_blob: win.DATA_BLOB = .{ .cbData = @intCast(data.len), .pbData = data.ptr };
        var out_blob: win.DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (win.CryptUnprotectData(&in_blob, null, null, null, null, win.CRYPTPROTECT_UI_FORBIDDEN, &out_blob) != 0) {
            defer _ = win.LocalFree(out_blob.pbData);
            const plain = out_blob.pbData.?[0..out_blob.cbData];
            const n = @min(plain.len, out.len);
            @memcpy(out[0..n], plain[0..n]);
            // best-effort: migrate the legacy blob to plaintext so future loads (and the veil) read it directly
            Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = plain }) catch {};
            log.info("secrets: migrated a legacy sealed secret to plaintext-local ({s})", .{p});
            return n;
        }
        // not a sealed blob — already plaintext; fall through
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

test "per-provider keys stay separate; legacy migrates to the current provider only" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.testing.allocator;
    const dir = "zig-secrets-pp-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var buf: [64]u8 = undefined;

    // two providers, two distinct keys — neither clobbers the other
    try std.testing.expect(saveFor(io, gpa, dir, "deepseek", "sk-deep"));
    try std.testing.expect(saveFor(io, gpa, dir, "openai", "sk-open"));
    try std.testing.expectEqualStrings("sk-deep", buf[0..loadFor(io, gpa, dir, "deepseek", &buf)]);
    try std.testing.expectEqualStrings("sk-open", buf[0..loadFor(io, gpa, dir, "openai", &buf)]);
    // a provider never given a key reads empty (no cross-provider leak)
    try std.testing.expectEqual(@as(usize, 0), loadFor(io, gpa, dir, "anthropic", &buf));

    // legacy: a single global key migrates to the CURRENT provider and is then gone; others stay empty
    const dir2 = "zig-secrets-mig-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dir2, .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir2) catch {};
    try std.testing.expect(save(io, gpa, dir2, "sk-legacy"));
    try std.testing.expectEqual(@as(usize, 9), migrateLegacy(io, gpa, dir2, "deepseek", &buf));
    try std.testing.expectEqualStrings("sk-legacy", buf[0..loadFor(io, gpa, dir2, "deepseek", &buf)]);
    try std.testing.expectEqual(@as(usize, 0), load(io, gpa, dir2, &buf)); // legacy file consumed
    try std.testing.expectEqual(@as(usize, 0), migrateLegacy(io, gpa, dir2, "openai", &buf)); // nothing left to migrate
}
