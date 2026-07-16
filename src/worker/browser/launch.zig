//! Headless-browser discovery + process launch for the shared CDP session. Pixel RAG's render stage and the
//! RSI browser driver BOTH drive one of these — see PIXEL_BROWSER_BLUEPRINT.md — so this is the single place a
//! browser process is found, spawned, and located on the DevTools wire. Nothing is bundled or installed: every
//! Windows box already ships Edge, so we discover the Chromium-based browser already present and spawn it
//! headless with an OS-assigned debugging port. Process handling mirrors control/supervisor.zig (spawn under a
//! mutex, hold the Child, kill via child.kill()); the caller owns the returned Child and must kill/reap it.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");

const log = std.log.scoped(.browser);

pub const Error = error{ NoBrowserFound, PortFileTimeout, BadPortFile };

/// Known Chromium-family install paths, most-preferred first. Edge is present on every modern Windows install;
/// Chrome is the common alternative. NL_BROWSER_BIN overrides this list entirely.
const win_candidates = [_][]const u8{
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
};
const posix_candidates = [_][]const u8{
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/microsoft-edge",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
};

fn exists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return true else |_| return false;
}

/// Resolve the browser executable. Order: NL_BROWSER_BIN env override → known install paths → (Windows) the
/// App Paths registry entry for msedge.exe via `reg query`. Returns a gpa-owned path; caller frees.
pub fn discover(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Error![]u8 {
    if (env.get("NL_BROWSER_BIN")) |p| {
        if (p.len > 0 and exists(io, p)) return gpa.dupe(u8, p) catch return error.NoBrowserFound;
    }
    const candidates = if (builtin.os.tag == .windows) &win_candidates else &posix_candidates;
    for (candidates) |c| if (exists(io, c)) return gpa.dupe(u8, c) catch return error.NoBrowserFound;
    if (builtin.os.tag == .windows) if (regAppPath(gpa, io)) |p| return p;
    return error.NoBrowserFound;
}

/// Windows-only fallback: read the default value of the msedge.exe App Paths key with `reg query` and return
/// its path if it exists on disk. The known-paths list already covers a normal Edge install; this catches a
/// non-default install location. gpa-owned on success.
fn regAppPath(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const key = "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\msedge.exe";
    const res = std.process.run(gpa, io, .{ .argv = &.{ "reg", "query", key, "/ve" } }) catch return null;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    // A line like: "    (Default)    REG_SZ    C:\Program Files (x86)\...\msedge.exe"
    var it = std.mem.tokenizeAny(u8, res.stdout, "\r\n");
    while (it.next()) |line| {
        const marker = std.mem.indexOf(u8, line, "REG_SZ") orelse continue;
        const raw = std.mem.trim(u8, line[marker + "REG_SZ".len ..], " \t");
        if (raw.len == 0) continue;
        if (!exists(io, raw)) continue;
        return gpa.dupe(u8, raw) catch return null;
    }
    return null;
}

pub const Opts = struct {
    headless: bool = true,
    /// Viewport the browser opens at — also the default screenshot tile width/height for Pixel RAG.
    width: u32 = 1280,
    height: u32 = 2000,
};

/// Spawn `browser_path` headless with an OS-assigned DevTools port, isolated to `user_data_dir` (created if
/// absent). The stale DevToolsActivePort file is removed first so readEndpoint() waits for the NEW process's
/// port, never a previous run's. Returns the live Child — the caller owns it (kill + reap on teardown). Stdio
/// is ignored and no console window pops (windowless parent), exactly like a worker spawn.
pub fn spawn(gpa: std.mem.Allocator, io: std.Io, browser_path: []const u8, user_data_dir: []const u8, opts: Opts) !std.process.Child {
    _ = std.Io.Dir.cwd().createDirPathStatus(io, user_data_dir, .default_dir) catch {};
    var pbuf: [1280]u8 = undefined;
    if (std.fmt.bufPrint(&pbuf, "{s}/DevToolsActivePort", .{user_data_dir})) |dp| {
        std.Io.Dir.cwd().deleteFile(io, dp) catch {};
    } else |_| {}

    const udd_flag = try std.fmt.allocPrint(gpa, "--user-data-dir={s}", .{user_data_dir});
    defer gpa.free(udd_flag);
    const win_flag = try std.fmt.allocPrint(gpa, "--window-size={d},{d}", .{ opts.width, opts.height });
    defer gpa.free(win_flag);

    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    try av.append(gpa, browser_path);
    if (opts.headless) try av.append(gpa, "--headless=new");
    try av.appendSlice(gpa, &.{
        "--remote-debugging-port=0", // OS-assigned; the real port lands in DevToolsActivePort
        udd_flag,
        win_flag,
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-gpu",
        "about:blank",
    });

    return std.process.spawn(io, .{
        .argv = av.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
}

pub const Endpoint = struct {
    port: u16,
    ws_path: []u8, // gpa-owned, e.g. "/devtools/browser/<uuid>"
};

/// Poll `<user_data_dir>/DevToolsActivePort` until the freshly-spawned browser writes it (or `timeout_ms`
/// elapses). The file is two lines: the chosen port, then the browser-level DevTools ws path. Returns both;
/// ws_path is gpa-owned.
pub fn readEndpoint(gpa: std.mem.Allocator, io: std.Io, user_data_dir: []const u8, timeout_ms: u32) Error!Endpoint {
    var pbuf: [1280]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/DevToolsActivePort", .{user_data_dir}) catch return error.BadPortFile;
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        const txt = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch {
            util.sleepMs(100);
            continue;
        };
        defer gpa.free(txt);
        var lines = std.mem.tokenizeAny(u8, txt, "\r\n");
        const port_s = lines.next() orelse return error.BadPortFile;
        const ws = lines.next() orelse {
            // port line present but ws path not flushed yet — retry
            util.sleepMs(100);
            continue;
        };
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, port_s, " \t"), 10) catch return error.BadPortFile;
        return .{ .port = port, .ws_path = gpa.dupe(u8, std.mem.trim(u8, ws, " \t")) catch return error.BadPortFile };
    }
    return error.PortFileTimeout;
}
