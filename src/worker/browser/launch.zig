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

/// Known Chromium-family install paths, most-preferred first (Edge-first: it ships on every modern Windows
/// install; Chrome is the common alternative). A caller preference (NL_BROWSER / server_config) only REORDERS
/// which family is tried first when it is actually installed — the whole list stays the fallback. NL_BROWSER_BIN
/// (a full exe path) overrides the list entirely.
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

/// The three Chromium-family browsers we discover. This is a family PREFERENCE (choose among installed
/// browsers), never an arbitrary path — that remains the NL_BROWSER_BIN operator escape.
pub const Family = enum { chrome, edge, chromium };

/// Which family a candidate path belongs to. Order matters: "chromium" must be tested before "chrome" (the
/// former does not contain the substring "chrome", but keeping it first documents the intent and is robust to
/// any future path spelling). msedge.exe → edge; google-chrome/chrome.exe → chrome; chromium* → chromium.
fn familyOf(path: []const u8) Family {
    if (std.ascii.indexOfIgnoreCase(path, "chromium") != null) return .chromium;
    if (std.ascii.indexOfIgnoreCase(path, "chrome") != null) return .chrome;
    if (std.ascii.indexOfIgnoreCase(path, "edge") != null) return .edge;
    return .chrome; // unreachable for our static lists; a harmless default that only affects ordering
}

fn parseFamily(s: []const u8) ?Family {
    if (std.ascii.eqlIgnoreCase(s, "chrome")) return .chrome;
    if (std.ascii.eqlIgnoreCase(s, "edge")) return .edge;
    if (std.ascii.eqlIgnoreCase(s, "chromium")) return .chromium;
    return null; // "" or anything unrecognized ⇒ no preference ⇒ keep the Edge-first default order
}

// Admin browser-family preference, PUBLISHED by server_config whenever its `browser` field changes (config →
// launcher push). discover() reads it as the fallback for NL_BROWSER because discover() is reached
// (session.Session.open) with only an env map and no ServerConfig handle, and exactly one server config is live
// per process. A tiny enum-name string an admin writes rarely; the release/acquire length pairs the buffer
// write with the read so an in-flight discover() never observes a torn slice (single-writer — server_config
// serializes its own writes under its config mutex before calling here).
var g_pref_buf: [16]u8 = undefined;
var g_pref_len = std.atomic.Value(usize).init(0);

/// Publish the admin's browser-family preference: "" | "chrome" | "edge" | "chromium". Blank (or anything that
/// does not fit the buffer) clears it back to the Edge-first default order. Called from server_config.
pub fn setPreferredBrowser(name: []const u8) void {
    const n = if (name.len <= g_pref_buf.len) name.len else 0;
    @memcpy(g_pref_buf[0..n], name[0..n]);
    g_pref_len.store(n, .release);
}

fn configuredFamily() ?Family {
    return parseFamily(g_pref_buf[0..g_pref_len.load(.acquire)]);
}

/// The family discover() should try FIRST: NL_BROWSER env wins (a per-process operator override), else the
/// admin's server_config `browser` field, else null → keep the historical Edge-first order.
fn preferredFamily(env: *const std.process.Environ.Map) ?Family {
    if (env.get("NL_BROWSER")) |v| {
        if (parseFamily(std.mem.trim(u8, v, " \r\n\t"))) |f| return f;
    }
    return configuredFamily();
}

fn exists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return true else |_| return false;
}

/// Resolve the browser executable. Order: NL_BROWSER_BIN env override → known install paths (a preferred
/// family, if chosen and installed, tried first) → (Windows) the App Paths registry entry for msedge.exe via
/// `reg query`. Returns a gpa-owned path; caller frees.
pub fn discover(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Error![]u8 {
    if (env.get("NL_BROWSER_BIN")) |p| {
        if (p.len > 0 and exists(io, p)) return gpa.dupe(u8, p) catch return error.NoBrowserFound;
    }
    const candidates = if (builtin.os.tag == .windows) &win_candidates else &posix_candidates;
    const pref = preferredFamily(env);
    // Preference pass: try the chosen family's known paths first, but ONLY when actually installed — an
    // uninstalled preference must never shadow a browser that is present.
    if (pref) |want| {
        for (candidates) |c| if (familyOf(c) == want and exists(io, c)) return gpa.dupe(u8, c) catch return error.NoBrowserFound;
    }
    // Fallback pass: the historical Edge-first order. Skip the preferred family — the pass above already
    // proved none of its paths exist — so this covers "preferred not installed" and "no preference set".
    for (candidates) |c| {
        if (pref != null and familyOf(c) == pref.?) continue;
        if (exists(io, c)) return gpa.dupe(u8, c) catch return error.NoBrowserFound;
    }
    if (builtin.os.tag == .windows) if (regAppPath(gpa, io)) |p| return p;
    return error.NoBrowserFound;
}

/// Remediation for error.NoBrowserFound. The browser is DISCOVERED, never installed, so a missing one is a
/// human fix the app can only NAME — surface THIS to the model instead of the bare error name. Static (no
/// allocation) and free of quotes/backslashes/control bytes, so it embeds directly in a JSON string value.
pub fn notFoundHint() []const u8 {
    return "no Chromium-family browser found — install Microsoft Edge or Google Chrome, or set NL_BROWSER_BIN to a browser executable";
}

/// Map a browser error to a model-facing message: NoBrowserFound becomes the actionable remediation above;
/// every other error keeps its name. A surfacing call site renders `errText(e)` in place of `@errorName(e)`.
pub fn errText(e: anyerror) []const u8 {
    return switch (e) {
        error.NoBrowserFound => notFoundHint(),
        else => @errorName(e),
    };
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

/// Reinforce the promo-suppression launch flags by pre-seeding the fresh profile (belt-and-suspenders; the
/// flags are the primary lever). `First Run` marks first-run as already done; Default/Preferences disables
/// profile sign-in + sync so the sync-confirmation modal can't appear. Written ONCE (only if absent) so later
/// launches never fight Edge's own rewrites. Best-effort — a failure just leaves the flags to do the work.
fn seedProfile(gpa: std.mem.Allocator, io: std.Io, user_data_dir: []const u8) void {
    const fr = std.fmt.allocPrint(gpa, "{s}/First Run", .{user_data_dir}) catch return;
    defer gpa.free(fr);
    if (!exists(io, fr)) std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fr, .data = "" }) catch {};

    const default_dir = std.fmt.allocPrint(gpa, "{s}/Default", .{user_data_dir}) catch return;
    defer gpa.free(default_dir);
    const prefs = std.fmt.allocPrint(gpa, "{s}/Preferences", .{default_dir}) catch return;
    defer gpa.free(prefs);
    if (exists(io, prefs)) return;
    _ = std.Io.Dir.cwd().createDirPathStatus(io, default_dir, .default_dir) catch {};
    const body =
        \\{"browser":{"has_seen_welcome_page":true,"check_default_browser":false},"signin":{"allowed":false,"allowed_on_next_startup":false},"sync":{"requested":false,"has_setup_completed":false}}
    ;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = prefs, .data = body }) catch {};
}

/// Spawn `browser_path` headless with an OS-assigned DevTools port, isolated to `user_data_dir` (created if
/// absent). The stale DevToolsActivePort file is removed first so readEndpoint() waits for the NEW process's
/// port, never a previous run's. Returns the live Child — the caller owns it (kill + reap on teardown). Stdio
/// is ignored and no console window pops (windowless parent), exactly like a worker spawn.
pub fn spawn(gpa: std.mem.Allocator, io: std.Io, browser_path: []const u8, user_data_dir: []const u8, opts: Opts) !std.process.Child {
    _ = std.Io.Dir.cwd().createDirPathStatus(io, user_data_dir, .default_dir) catch {};
    seedProfile(gpa, io, user_data_dir);
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
    });
    // Accessibility hardening — a HEADFUL Edge on a fresh profile that Windows-SSO implicitly signs in will pop
    // the browser-chrome "We are now syncing your data / Got it" modal (a constrained-window WebUI, NOT page DOM
    // — unreachable by our snapshot/click). We can't dismiss it, so we suppress the implicit-signin→sync→promo
    // chain at launch. `--disable-features` MUST be a single CSV switch (repeated switches don't reliably merge).
    // `AutomationControlled` off drops the navigator.webdriver automation fingerprint at the source, so the
    // user's own assistive session isn't pre-emptively degraded (this is NOT captcha evasion). All harmless
    // headless too. Sources: Microsoft Edge policy docs (ImplicitSignInEnabled/BrowserSignin/SyncDisabled),
    // chromium-edge-launcher default flags.
    try av.appendSlice(gpa, &.{
        "--disable-sync", // sync never runs ⇒ the "syncing your data" confirmation never fires (primary lever)
        "--disable-features=msImplicitSignin,msEdgeWelcomeExperience,EdgeSyncPromotion,AutomationControlled",
        "--disable-blink-features=AutomationControlled", // clears navigator.webdriver at the Blink source
        "--disable-search-engine-choice-screen", // the 2024+ choice screen blocks startup on some locales
        "--propagate-iph-for-testing", // no-arg ⇒ suppresses in-product-help / feature-tour nudge bubbles
        "--no-service-autorun",
        "--disable-background-networking", // background promo/experiment/field-trial pulls that can spawn UI
        "--disable-component-update",
        "--disable-default-apps",
        "--metrics-recording-only",
    });
    try av.append(gpa, "about:blank");

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

test "familyOf classifies every known candidate path" {
    const t = std.testing;
    // Windows install paths.
    try t.expectEqual(Family.edge, familyOf("C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"));
    try t.expectEqual(Family.chrome, familyOf("C:/Program Files/Google/Chrome/Application/chrome.exe"));
    // POSIX install paths — chromium must NOT be misread as chrome.
    try t.expectEqual(Family.chrome, familyOf("/usr/bin/google-chrome"));
    try t.expectEqual(Family.chromium, familyOf("/usr/bin/chromium"));
    try t.expectEqual(Family.chromium, familyOf("/usr/bin/chromium-browser"));
    try t.expectEqual(Family.edge, familyOf("/usr/bin/microsoft-edge"));
}

test "parseFamily accepts the known names case-insensitively and rejects everything else" {
    const t = std.testing;
    try t.expectEqual(Family.chrome, parseFamily("Chrome").?);
    try t.expectEqual(Family.edge, parseFamily("EDGE").?);
    try t.expectEqual(Family.chromium, parseFamily("chromium").?);
    try t.expect(parseFamily("") == null);
    try t.expect(parseFamily("firefox") == null); // an unknown family ⇒ no preference ⇒ default order
}

test "preferredFamily: NL_BROWSER env overrides the published server_config preference" {
    const t = std.testing;
    // Published admin preference = chrome; an env override to edge must win.
    setPreferredBrowser("chrome");
    defer setPreferredBrowser(""); // don't leak the global into other tests
    try t.expectEqual(Family.chrome, configuredFamily().?);

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("NL_BROWSER", "edge");
    try t.expectEqual(Family.edge, preferredFamily(&env).?);

    // A garbage env value falls through to the published config preference rather than clearing it.
    try env.put("NL_BROWSER", "netscape");
    try t.expectEqual(Family.chrome, preferredFamily(&env).?);
}
