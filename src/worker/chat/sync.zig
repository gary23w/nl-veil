//! chat/sync.zig — the conversation-workdir SYNC protocol's shared pieces, used by the server engine and
//! every client (the CLI calls these in-process; the desk spawns `veil sync-manifest` / `veil sync-read`,
//! which call the same functions — one implementation, no per-client twins).
//!
//! Design: rsync-lite over the existing delegation channel, instead of a real file server (SMB/WebDAV would
//! mean a new port, its own auth surface, OS mounts, and idle chatter). A sync happens only at the two
//! moments state actually crosses the machine boundary — a cast needs the client's files (client→server), a
//! finished hive's files need to reach the client (server→client) — and each moment costs ONE manifest
//! round-trip plus only the files whose content hash differs. A same-disk install (desk + server on one
//! machine sharing the data dir) is detected by a probe token in the manifest exchange and short-circuits to
//! ZERO transfers. No daemon, no watcher, no polling: idle cost is exactly zero on both sides.
//!
//! Wire shapes (all ride the existing events/tool_result channel):
//!   server → client  {"kind":"sync_request","id":..}            ask for the workdir manifest (+ probe)
//!   client → server  {"probe":"<token|empty>","files":[{"p","s","h"}...]}   posted to /tool_result
//!   server → client  {"kind":"file_pull","id":..,"paths":[..]}  ask for those files' contents
//!   client → server  {"files":[{"p","c"}...]}                   posted to /tool_result
//!   server → client  {"kind":"file_sync","path","content"}      push one file (hive output), as before

const std = @import("std");
const llm = @import("../llm.zig");

pub const FILE_CAP: usize = 512 << 10; // per-file ceiling — an oversized file is skipped, not clipped
pub const TOTAL_CAP: usize = 4 << 20; // total content budget per transfer batch
pub const MAX_FILES: usize = 64; // manifest / batch entry ceiling
pub const MAX_DEPTH: usize = 4; // workdir-relative recursion bound
/// The same-disk probe: the server writes a random token here (in ITS copy of the workdir) right before a
/// sync_request; the client's manifest response echoes the file's content if IT can see one. A match means
/// both sides read the same directory — no transfer can ever be needed for this conversation.
pub const PROBE_NAME: []const u8 = ".sync_probe";

/// One manifest row: workdir-relative path, size, and FNV-1a-64 content hash (hex).
pub const Entry = struct { p: []const u8 = "", s: u64 = 0, h: []const u8 = "" };
/// The parsed sync_request response.
pub const ManifestResp = struct { probe: []const u8 = "", files: []Entry = &.{} };
/// One pulled file.
pub const PulledFile = struct { p: []const u8 = "", c: []const u8 = "" };
/// The parsed file_pull response.
pub const PullResp = struct { files: []PulledFile = &.{} };

/// FNV-1a 64 of `bytes` as 16 lowercase hex chars in `out`. Non-crypto on purpose: this detects drift between
/// two copies of the user's own files, not an adversary — and it hashes at memory speed.
pub fn hashHex(bytes: []const u8, out: *[16]u8) []const u8 {
    const h = std.hash.Fnv1a_64.hash(bytes);
    return std.fmt.bufPrint(out, "{x:0>16}", .{h}) catch out[0..16];
}

/// A sync path must stay INSIDE the workdir: relative, forward slashes only, no "."/".." segments, no drive
/// letters or ADS colons. The shared checker every side applies before reading or writing a synced path.
pub fn safeSyncPath(p: []const u8) bool {
    if (p.len == 0 or p.len > 400) return false;
    if (p[0] == '/' or p[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, p, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, p, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false; // "//" or a trailing '/'
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// TEXT ONLY (v1): a control byte beyond \n\r\t in the first KB marks a binary — it can't ride a JSON string,
/// and \uXXXX escapes round-trip lossily through the small client unescapers. Binaries are skipped everywhere
/// (manifest AND transfer) so both sides agree on the syncable set.
pub fn isTextContent(data: []const u8) bool {
    for (data[0..@min(data.len, 1024)]) |b| {
        if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') return false;
    }
    return true;
}

/// Build the complete sync_request response for `workdir`: {"probe":"<token|empty>","files":[{p,s,h}...]}.
/// gpa-owned. Never errors — a missing/unreadable workdir yields an empty manifest (a fresh client is valid).
pub fn manifestResponse(gpa: std.mem.Allocator, io: std.Io, workdir: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"probe\":") catch return dupe(gpa, "{\"probe\":\"\",\"files\":[]}");
    // the probe is an EXPLICIT read (dot files stay out of the walk) — present only on a shared disk
    var pb: [1200]u8 = undefined;
    var probe: []const u8 = "";
    var probe_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}/{s}", .{ workdir, PROBE_NAME })) |pp| {
        if (std.Io.Dir.cwd().readFileAlloc(io, pp, gpa, .limited(128)) catch null) |tok| {
            const n = @min(tok.len, probe_buf.len);
            @memcpy(probe_buf[0..n], tok[0..n]);
            probe = std.mem.trim(u8, probe_buf[0..n], " \r\n\t");
            gpa.free(tok);
        }
    } else |_| {}
    llm.jstr(gpa, &out, probe) catch return dupe(gpa, "{\"probe\":\"\",\"files\":[]}");
    out.appendSlice(gpa, ",\"files\":[") catch return dupe(gpa, "{\"probe\":\"\",\"files\":[]}");
    var count: usize = 0;
    var budget: usize = TOTAL_CAP;
    walkManifest(gpa, io, workdir, "", 0, &out, &count, &budget);
    out.appendSlice(gpa, "]}") catch return dupe(gpa, "{\"probe\":\"\",\"files\":[]}");
    return gpa.dupe(u8, out.items) catch dupe(gpa, "{\"probe\":\"\",\"files\":[]}");
}

fn walkManifest(gpa: std.mem.Allocator, io: std.Io, abs_dir: []const u8, rel: []const u8, depth: usize, out: *std.ArrayListUnmanaged(u8), count: *usize, budget: *usize) void {
    if (depth > MAX_DEPTH or count.* >= MAX_FILES) return;
    var dir = std.Io.Dir.cwd().openDir(io, abs_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (count.* >= MAX_FILES) return;
        if (ent.name.len == 0 or ent.name[0] == '.') continue;
        var ab: [1600]u8 = undefined;
        const child_abs = std.fmt.bufPrint(&ab, "{s}/{s}", .{ abs_dir, ent.name }) catch continue;
        var rb: [512]u8 = undefined;
        const child_rel = (if (rel.len == 0)
            std.fmt.bufPrint(&rb, "{s}", .{ent.name})
        else
            std.fmt.bufPrint(&rb, "{s}/{s}", .{ rel, ent.name })) catch continue;
        switch (ent.kind) {
            .directory => walkManifest(gpa, io, child_abs, child_rel, depth + 1, out, count, budget),
            .file => {
                // the hash requires the content anyway (bounded), so text-sniff + hash in one read
                const data = std.Io.Dir.cwd().readFileAlloc(io, child_abs, gpa, .limited(FILE_CAP)) catch continue;
                defer gpa.free(data);
                if (data.len == 0 or data.len > budget.* or !isTextContent(data)) continue;
                var hb: [16]u8 = undefined;
                const h = hashHex(data, &hb);
                if (count.* > 0) out.append(gpa, ',') catch return;
                out.appendSlice(gpa, "{\"p\":") catch return;
                llm.jstr(gpa, out, child_rel) catch return;
                out.print(gpa, ",\"s\":{d},\"h\":\"{s}\"}}", .{ data.len, h }) catch return;
                budget.* -= data.len;
                count.* += 1;
            },
            else => {},
        }
    }
}

/// Answer a file_pull: parse {"paths":[..]} out of the frame line, read each (sanitized, text-only, capped),
/// and build {"files":[{"p","c"}...]}. gpa-owned. Unknown/unsafe/oversized paths are silently skipped — the
/// server treats an absent entry as "could not sync" and proceeds without it.
pub fn readResponse(gpa: std.mem.Allocator, io: std.Io, workdir: []const u8, frame_json: []const u8) []u8 {
    const Req = struct { paths: [][]const u8 = &.{} };
    const parsed = std.json.parseFromSlice(Req, gpa, frame_json, .{ .ignore_unknown_fields = true }) catch
        return dupe(gpa, "{\"files\":[]}");
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"files\":[") catch return dupe(gpa, "{\"files\":[]}");
    var count: usize = 0;
    var budget: usize = TOTAL_CAP;
    for (parsed.value.paths) |p| {
        if (count >= MAX_FILES or budget == 0) break;
        if (!safeSyncPath(p)) continue;
        var fb: [1600]u8 = undefined;
        const full = std.fmt.bufPrint(&fb, "{s}/{s}", .{ workdir, p }) catch continue;
        const data = std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(FILE_CAP)) catch continue;
        defer gpa.free(data);
        if (data.len == 0 or data.len > budget or !isTextContent(data)) continue;
        const ok = blk: {
            if (count > 0) out.append(gpa, ',') catch break :blk false;
            out.appendSlice(gpa, "{\"p\":") catch break :blk false;
            llm.jstr(gpa, &out, p) catch break :blk false;
            out.appendSlice(gpa, ",\"c\":") catch break :blk false;
            llm.jstr(gpa, &out, data) catch break :blk false;
            out.append(gpa, '}') catch break :blk false;
            break :blk true;
        };
        if (!ok) break;
        budget -= data.len;
        count += 1;
    }
    out.appendSlice(gpa, "]}") catch return dupe(gpa, "{\"files\":[]}");
    return gpa.dupe(u8, out.items) catch dupe(gpa, "{\"files\":[]}");
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast(s[0..0]);
}

// ------------------------------------------------------------------------------------------------- tests

test "hashHex: stable, distinct, 16 lowercase hex" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    const h1 = hashHex("hello world", &a);
    const h2 = hashHex("hello world", &b);
    try std.testing.expectEqualStrings(h1, h2);
    var c: [16]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, hashHex("hello worlds", &c), h1));
    try std.testing.expectEqual(@as(usize, 16), h1.len);
    for (h1) |ch| try std.testing.expect(std.ascii.isHex(ch) and !std.ascii.isUpper(ch));
}

test "safeSyncPath: workdir-relative only" {
    try std.testing.expect(safeSyncPath("index.html"));
    try std.testing.expect(safeSyncPath("journal/ada.md"));
    try std.testing.expect(!safeSyncPath("../up.txt"));
    try std.testing.expect(!safeSyncPath("a/./b"));
    try std.testing.expect(!safeSyncPath("/abs"));
    try std.testing.expect(!safeSyncPath("C:/x"));
    try std.testing.expect(!safeSyncPath("a\\b"));
    try std.testing.expect(!safeSyncPath(""));
}

test "isTextContent: newlines/tabs pass, control bytes and NUL don't" {
    try std.testing.expect(isTextContent("# md\nline\ttwo\r\n"));
    try std.testing.expect(!isTextContent("PK\x03\x04zipdata"));
    try std.testing.expect(!isTextContent("a\x00b"));
    try std.testing.expect(isTextContent("caf\xc3\xa9 utf8 ok"));
}

test "ManifestResp/PullResp: wire shapes parse with ignore_unknown_fields" {
    const gpa = std.testing.allocator;
    const m = std.json.parseFromSlice(ManifestResp, gpa, "{\"probe\":\"tok1\",\"files\":[{\"p\":\"a.txt\",\"s\":3,\"h\":\"00000000000000ab\"}],\"extra\":1}", .{ .ignore_unknown_fields = true }) catch unreachable;
    defer m.deinit();
    try std.testing.expectEqualStrings("tok1", m.value.probe);
    try std.testing.expectEqual(@as(usize, 1), m.value.files.len);
    try std.testing.expectEqualStrings("a.txt", m.value.files[0].p);
    const r = std.json.parseFromSlice(PullResp, gpa, "{\"files\":[{\"p\":\"a\",\"c\":\"body\"}]}", .{ .ignore_unknown_fields = true }) catch unreachable;
    defer r.deinit();
    try std.testing.expectEqualStrings("body", r.value.files[0].c);
}
