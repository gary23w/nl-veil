//! Local-host daemon + its client side. Round-2 (see CLIENT_DRIVER_MCP_BLUEPRINT.md): the browser/pixel/mcp
//! tools run on the CLIENT by default, delegated from the server. But the desk runs each delegated tool as a
//! FRESH `veil exec-tool` subprocess, so a process-global browser session can't survive between navigate and
//! read. This daemon is the fix: a per-machine background `veil local-host` process that OWNS the stateful
//! local resources (browser sessions now; MCP connections later) behind the loopback broker, so every
//! subprocess-per-call client shares ONE session.
//!
//! - runDaemon(): the `veil local-host` entry — start the broker, publish {port,token} to a discovery file on
//!   LOCAL temp (never OneDrive), then idle-exit after no activity.
//! - ensure()/forward(): the client side — `exec-tool` (roam=true) reads the discovery file, lazily spawns the
//!   daemon if absent/dead, and forwards the browser command to it over loopback. No desk changes needed.

const std = @import("std");
const builtin = @import("builtin");
const broker = @import("broker.zig");
const manager = @import("manager.zig");
const util = @import("util.zig");
const httpc = @import("../httpc.zig");

const log = std.log.scoped(.browser);

const IDLE_EXIT_S: i64 = 300; // exit after 5 min with no live sessions and no recent activity

pub const Info = struct { port: u16, token: [32]u8 };

/// Discovery file path on LOCAL temp (OneDrive would lock/delay it). gpa-owned.
fn discoveryPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    const base = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR") orelse ".";
    return std.fmt.allocPrint(gpa, "{s}/nl-veil-localhost.json", .{base}) catch null;
}

// ------------------------------------------------------------------------------------------ daemon (server)

/// The `veil local-host` entry: bring up the loopback broker, publish it, and idle-exit. Blocks.
pub fn runDaemon(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    const info = broker.ensure(gpa, io, env) orelse {
        log.warn("local-host: broker failed to start", .{});
        return;
    };
    const path = discoveryPath(gpa, env) orelse return;
    defer gpa.free(path);
    writeDiscovery(gpa, io, path, info.port, info.token);
    log.info("local-host daemon listening on 127.0.0.1:{d}", .{info.port});

    const started = std.Io.Timestamp.now(io, .real).toSeconds();
    while (true) {
        util.sleepMs(3000);
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        // sweep, don't just count: an abandoned session used to hold liveCount above 0 forever, so the
        // daemon (and its headless browsers) never idle-exited once anything had opened a session.
        const live = manager.sweepIdle(gpa, io, manager.SESSION_IDLE_S);
        const last = manager.lastActivity();
        const idle_since = if (last != 0) last else started;
        if (live == 0 and now - idle_since > IDLE_EXIT_S) break;
    }
    manager.closeAll(gpa, io);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    log.info("local-host daemon idle-exited", .{});
}

fn writeDiscovery(gpa: std.mem.Allocator, io: std.Io, path: []const u8, port: u16, token: []const u8) void {
    const pid: u32 = if (builtin.os.tag == .windows) std.os.windows.GetCurrentProcessId() else @intCast(std.os.linux.getpid());
    const body = std.fmt.allocPrint(gpa, "{{\"port\":{d},\"token\":\"{s}\",\"pid\":{d}}}", .{ port, token, pid }) catch return;
    defer gpa.free(body);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch {};
}

// ------------------------------------------------------------------------------------------ client side

const Disc = struct { port: u16 = 0, token: []const u8 = "", pid: u32 = 0 };

fn readInfo(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?Info {
    const txt = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch return null;
    defer gpa.free(txt);
    const p = std.json.parseFromSlice(Disc, gpa, txt, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (p.value.port == 0 or p.value.token.len != 32) return null;
    var info: Info = .{ .port = p.value.port, .token = undefined };
    @memcpy(&info.token, p.value.token[0..32]);
    return info;
}

/// A quick liveness ping to a candidate daemon (POST action:ping). True if it answered.
fn reachable(gpa: std.mem.Allocator, io: std.Io, info: Info) bool {
    const body = std.fmt.allocPrint(gpa, "{{\"token\":\"{s}\",\"key\":\"_\",\"action\":\"ping\",\"params\":{{}}}}", .{info.token}) catch return false;
    defer gpa.free(body);
    switch (httpc.request(io, gpa, .{ .method = "POST", .port = info.port, .path = "/", .body = body, .timeout_s = 3, .cap = 4 << 10 })) {
        .ok => |resp| {
            const ok = std.mem.indexOf(u8, resp.body, "pong") != null;
            if (resp.body.len > 0) gpa.free(resp.body);
            return ok;
        },
        else => return false,
    }
}

fn spawnDaemon(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    var exebuf: [4096]u8 = undefined;
    const n = std.process.executablePath(io, &exebuf) catch return;
    const self_exe = exebuf[0..n];
    // WINDOWS: run the daemon from a TEMP COPY of the exe, not the install path — a daemon that holds the
    // install exe open forces every rebuild/restart script to kill it, which is exactly how the shared
    // browser died on every restart (a cold Edge for the next call, every time). The daemon needs no paths
    // of its own (the `local-host` entry short-circuits before resolvePaths), so running from TEMP is safe.
    // Any copy trouble (or the copy locked by a live-but-unreachable daemon) falls back to the install exe —
    // worse (pins the file again) but functional. POSIX doesn't lock running binaries, so no copy there.
    var daemon_exe: []const u8 = self_exe;
    var cpb: [1024]u8 = undefined;
    if (builtin.os.tag == .windows) {
        if (env.get("TEMP") orelse env.get("TMP")) |tmp| blk: {
            const copy_path = std.fmt.bufPrint(&cpb, "{s}/nl-veil-localhost.exe", .{tmp}) catch break :blk;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, self_exe, gpa, .limited(256 << 20)) catch break :blk;
            defer gpa.free(bytes);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = copy_path, .data = bytes }) catch break :blk;
            daemon_exe = copy_path;
        }
    }
    const argv = [_][]const u8{ daemon_exe, "local-host" };
    var mcopy = env.clone(gpa) catch {
        _ = std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true }) catch {};
        return;
    };
    defer mcopy.deinit();
    _ = std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true, .environ_map = &mcopy }) catch {};
}

/// Return a reachable daemon, spawning one and waiting for it if needed. null if it could not be started.
pub fn ensure(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?Info {
    const path = discoveryPath(gpa, env) orelse return null;
    defer gpa.free(path);
    if (readInfo(gpa, io, path)) |info| {
        if (reachable(gpa, io, info)) return info;
    }
    spawnDaemon(gpa, io, env);
    var waited: u32 = 0;
    while (waited < 12_000) : (waited += 200) {
        util.sleepMs(200); // raw-thread-safe: this runs on an httpz worker / exec-tool thread, where io.sleep throws
        if (readInfo(gpa, io, path)) |info| {
            if (reachable(gpa, io, info)) return info;
        }
    }
    return null;
}

/// Forward one browser action to the local-host daemon (starting it if needed). `params_json` is a JSON object.
/// Returns the daemon's JSON response (gpa-owned), or a JSON error.
pub fn forward(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, action: []const u8, params_json: []const u8) []u8 {
    const info = ensure(gpa, io, env) orelse
        return gpa.dupe(u8, "{\"ok\":false,\"error\":\"could not start the local browser host on this machine\"}") catch @constCast("");
    const key_lit = std.json.Stringify.valueAlloc(gpa, key, .{}) catch return gpa.dupe(u8, "{\"ok\":false,\"error\":\"oom\"}") catch @constCast("");
    defer gpa.free(key_lit);
    const params = if (std.mem.trim(u8, params_json, " \r\n\t").len == 0) "{}" else params_json;
    const body = std.fmt.allocPrint(gpa, "{{\"token\":\"{s}\",\"key\":{s},\"action\":\"{s}\",\"params\":{s}}}", .{ info.token, key_lit, action, params }) catch
        return gpa.dupe(u8, "{\"ok\":false,\"error\":\"oom\"}") catch @constCast("");
    defer gpa.free(body);
    switch (httpc.request(io, gpa, .{ .method = "POST", .port = info.port, .path = "/", .body = body, .timeout_s = 180, .cap = 48 << 20 })) {
        .ok => |resp| return if (resp.body.len > 0) resp.body else (gpa.dupe(u8, "{\"ok\":true}") catch @constCast("")),
        else => return gpa.dupe(u8, "{\"ok\":false,\"error\":\"local browser host unreachable\"}") catch @constCast(""),
    }
}

// ---------------------------------------------------------------------------
// tests — the DISCOVERY FILE is how a tool call finds the machine's browser daemon: it carries the
// port to dial and the token that authorises the dial. A stale or corrupt one must yield NOTHING,
// never a half-read port/token, because the caller would send browser traffic somewhere arbitrary.
// No browser and no daemon needed for any of this. See harness/TESTING.md.
// ---------------------------------------------------------------------------

test "discovery file: a real round trip, and every malformed shape reads as absent" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-host-disc-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    const path = root ++ "/nl-veil-localhost.json";

    // A file nobody wrote is absent, not a crash and not a zero-port "success".
    try std.testing.expect(readInfo(gpa, io, path) == null);

    // Round trip: what the daemon publishes is exactly what a client reads back.
    const token = "0123456789abcdef0123456789abcdef"; // 32, the only length readInfo accepts
    writeDiscovery(gpa, io, path, 45123, token);
    const got = readInfo(gpa, io, path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 45123), got.port);
    try std.testing.expectEqualStrings(token, &got.token);

    // port 0 means the broker never bound. Reading it as a live daemon would dial port 0.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"port\":0,\"token\":\"" ++ token ++ "\",\"pid\":1}" });
    try std.testing.expect(readInfo(gpa, io, path) == null);

    // A SHORT token is the sharp one: info.token is a fixed [32]u8 filled by @memcpy, so the length
    // check is the only thing standing between a truncated file and a read past the parsed slice.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"port\":45123,\"token\":\"abc\",\"pid\":1}" });
    try std.testing.expect(readInfo(gpa, io, path) == null);
    // ...and a LONG one is refused too rather than silently truncated to the first 32 bytes.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"port\":45123,\"token\":\"" ++ token ++ "extra\",\"pid\":1}" });
    try std.testing.expect(readInfo(gpa, io, path) == null);

    // Not JSON at all (a half-written file, a crashed daemon) reads as absent.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"port\":451" });
    try std.testing.expect(readInfo(gpa, io, path) == null);

    // Unknown fields are IGNORED on purpose: a newer daemon may publish more, and an older client
    // must still find it rather than refusing the whole file.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"port\":45123,\"token\":\"" ++ token ++ "\",\"pid\":1,\"future\":\"x\"}" });
    try std.testing.expect(readInfo(gpa, io, path) != null);
}

test "discoveryPath prefers local temp, and falls back rather than failing" {
    // It must NOT land under the repo/OneDrive (the header's reason: OneDrive locks and delays it).
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try env.put("TEMP", "C:/localtmp");
    const p1 = discoveryPath(gpa, &env) orelse return error.TestUnexpectedResult;
    defer gpa.free(p1);
    try std.testing.expectEqualStrings("C:/localtmp/nl-veil-localhost.json", p1);

    // TMPDIR is the POSIX spelling and must work when TEMP/TMP are absent.
    var env2 = std.process.Environ.Map.init(gpa);
    defer env2.deinit();
    try env2.put("TMPDIR", "/var/tmp");
    const p2 = discoveryPath(gpa, &env2) orelse return error.TestUnexpectedResult;
    defer gpa.free(p2);
    try std.testing.expectEqualStrings("/var/tmp/nl-veil-localhost.json", p2);

    // No temp var at all: still returns a usable relative path instead of null, so discovery
    // degrades to the working directory rather than the daemon becoming unfindable.
    var env3 = std.process.Environ.Map.init(gpa);
    defer env3.deinit();
    const p3 = discoveryPath(gpa, &env3) orelse return error.TestUnexpectedResult;
    defer gpa.free(p3);
    try std.testing.expectEqualStrings("./nl-veil-localhost.json", p3);
}
