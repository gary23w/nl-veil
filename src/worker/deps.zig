//! Dependency probe — DETECT + INSTRUCT ONLY. The app spawns external binaries (python, node, npm, curl,
//! git, a Chromium-family browser) all over the toolbelt. When one is MISSING the old behaviour was a flat
//! "X failed to run" or a silent empty string — indistinguishable from a script that ran and crashed, and
//! for curl it silently masqueraded as "internet down". This module answers ONE question precisely and
//! safely: is dependency <name> present, and if not, what exactly should the user do about it.
//!
//! It NEVER installs, downloads, or mutates anything. A probe resolves the binary on PATH (`where` on
//! Windows, `which` on POSIX), honours an NL_<DEP>_BIN override where one makes sense, and best-effort reads
//! `--version`. A missing binary is a NORMAL answer (present=false + a hint), never an error. The hint
//! strings are the entire value of the feature — a human reads one and knows exactly what to type.
const std = @import("std");
const builtin = @import("builtin");
const launch = @import("browser/launch.zig");

pub const Dep = struct {
    /// "python" | "node" | "npm" | "curl" | "git" | "browser". A STATIC literal — the caller does NOT free it.
    name: []const u8,
    present: bool,
    /// gpa-owned, "" if unknown/absent. Caller frees.
    version: []const u8,
    /// gpa-owned remediation, "" when present. Caller frees.
    hint: []const u8,
};

/// The standard set surfaced on the health page, in a stable display order.
pub const standard = [_][]const u8{ "python", "node", "npm", "curl", "git", "browser" };

/// Per-dependency detection metadata + its remediation text. `browser` is NOT in here — it reuses
/// browser/launch.zig discover() (Edge/Chrome + NL_BROWSER_BIN) rather than duplicating that resolution.
const Spec = struct {
    key: []const u8, // canonical name returned in Dep.name
    win_bin: []const u8, // binary to resolve on Windows
    nix_bin: []const u8, // binary to resolve on POSIX
    env_override: []const u8, // NL_<DEP>_BIN full-path override, "" if none
    remedy: []const u8, // the actionable "here is how to get it" message
};

// The hints name the Windows winget id AND the vendor download AND the env override, so the same string is
// actionable on any host the app runs on. Kept deliberately concrete — this text IS the feature.
const specs = [_]Spec{
    .{
        .key = "python",
        .win_bin = "python",
        .nix_bin = "python3",
        .env_override = "NL_PYTHON_BIN",
        .remedy = "python not found on PATH — install it (Windows: winget install Python.Python.3, then reopen the shell; macOS: brew install python; Debian/Ubuntu: apt install python3) or set NL_PYTHON_BIN to the full path of an existing interpreter",
    },
    .{
        .key = "node",
        .win_bin = "node",
        .nix_bin = "node",
        .env_override = "NL_NODE_BIN",
        .remedy = "node not found on PATH — install Node.js from nodejs.org (Windows: winget install OpenJS.NodeJS.LTS; macOS: brew install node; Debian/Ubuntu: apt install nodejs) or set NL_NODE_BIN to the full path of the node executable",
    },
    .{
        .key = "npm",
        .win_bin = "npm",
        .nix_bin = "npm",
        .env_override = "NL_NPM_BIN",
        .remedy = "npm not found on PATH — it ships with Node.js from nodejs.org (Windows: winget install OpenJS.NodeJS.LTS; macOS: brew install node; Debian/Ubuntu: apt install npm) or set NL_NPM_BIN to the full path of the npm launcher (npm.cmd on Windows)",
    },
    .{
        .key = "curl",
        .win_bin = "curl",
        .nix_bin = "curl",
        .env_override = "NL_CURL_BIN",
        .remedy = "curl not found on PATH — all web fetch/search routes through curl, so a missing curl disables remote HTTP. Windows 10+ ships curl in System32 (repair your PATH); otherwise winget install cURL.cURL; macOS has it preinstalled or brew install curl; Debian/Ubuntu: apt install curl. Or set NL_CURL_BIN to the full path of the curl executable",
    },
    .{
        .key = "git",
        .win_bin = "git",
        .nix_bin = "git",
        .env_override = "NL_GIT_BIN",
        .remedy = "git not found on PATH — install it from git-scm.com (Windows: winget install Git.Git; macOS: brew install git or xcode-select --install; Debian/Ubuntu: apt install git) or set NL_GIT_BIN to the full path of the git executable",
    },
};

// Browser remediation lives apart because discovery lives apart (launch.zig). Referenced by probeBrowser
// AND hint("browser").
const browser_remedy = "no Chromium-family browser found — install Microsoft Edge or Google Chrome (Windows ships Edge by default; macOS: brew install --cask google-chrome; Debian/Ubuntu: apt install chromium) or set NL_BROWSER_BIN to the full path of a Chromium/Edge/Chrome executable";

fn specFor(name: []const u8) ?Spec {
    for (specs) |s| if (std.mem.eql(u8, s.key, name)) return s;
    return null;
}

/// True when a std.process.run error means the BINARY ITSELF could not be started — it isn't on PATH, an
/// override points at nothing, or the target isn't a runnable image — as opposed to a program that DID
/// start and then produced too much output, hung, or hit a resource limit. This is the exact line the
/// detect-only feature draws: ONLY a genuinely-absent/unstartable binary earns a remediation hint; every
/// other error keeps the caller's original "it ran and something went wrong" behaviour. Mirrors the swarm
/// acceptance gate's "not recognized" vs "ran and failed" split. A non-zero EXIT never reaches here — that
/// is a RunResult, not an error — so this only ever sees spawn/IO failures.
pub fn isSpawnMissing(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, // the binary is not on PATH (the common case) / an override points at nothing
        error.NotDir, // a path component of an override isn't a directory
        error.IsDir, // the resolved path is a directory, not an executable
        error.InvalidExe, // present but not a runnable image
        error.InvalidName, // a malformed path (a bad override value)
        error.AccessDenied, // present but the OS refused to start it
        error.PermissionDenied,
        => true,
        // StreamTooLong / timeout / OutOfMemory / fd-quota / resource limits ⇒ the program RAN or the
        // failure is internal — NOT a missing dependency.
        else => false,
    };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return true else |_| return false;
}

/// Best-effort `<invoke> --version`, first non-blank line, clipped. NEVER fails the probe: any error (the
/// tool lacks --version, prints slowly, hangs) yields "". Most tools print to stdout; a few (older python)
/// use stderr, so we fall back. Bounded by a short timeout so a wedged binary can't stall a health check.
fn versionOf(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, invoke: []const u8) []const u8 {
    const argv = [_][]const u8{ invoke, "--version" };
    const r = std.process.run(gpa, io, .{
        .argv = &argv,
        .environ_map = env,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch return "";
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const src = if (std.mem.trim(u8, r.stdout, " \r\n\t").len > 0) r.stdout else r.stderr;
    var it = std.mem.tokenizeAny(u8, src, "\r\n");
    const first = it.next() orelse return "";
    const line = std.mem.trim(u8, first, " \t");
    if (line.len == 0) return "";
    return gpa.dupe(u8, if (line.len > 120) line[0..120] else line) catch "";
}

/// Resolve `bin` on PATH WITHOUT executing the target — `where` (Windows) / `which` (POSIX) just print the
/// path. Returns a gpa-owned resolved path (first hit) or null if absent. If the locator itself can't be
/// spawned (a stripped container with no `which`), fall back to a direct `<bin> --version` and treat a
/// spawn-missing error as "absent" — so a missing locator never masquerades as a missing dependency.
fn onPath(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, bin: []const u8) ?[]u8 {
    const locator = if (builtin.os.tag == .windows) "where" else "which";
    const argv = [_][]const u8{ locator, bin };
    const r = std.process.run(gpa, io, .{
        .argv = &argv,
        .environ_map = env,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch |e| {
        if (isSpawnMissing(e)) return probeDirect(gpa, io, env, bin);
        return null;
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    // The locator RAN: a non-zero exit means it searched PATH and found nothing → absent.
    if (r.term != .exited or r.term.exited != 0) return null;
    var it = std.mem.tokenizeAny(u8, r.stdout, "\r\n");
    const first = it.next() orelse return null;
    const path = std.mem.trim(u8, first, " \t");
    if (path.len == 0) return null;
    return gpa.dupe(u8, path) catch null;
}

/// Fallback presence check when the PATH locator is itself missing: try to START the binary (`--version`).
/// A spawn-missing error ⇒ absent (null). Anything else (it ran, or it hung/over-produced) ⇒ present; we
/// don't know the path, so we hand back the bare name as the "resolved" marker.
fn probeDirect(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, bin: []const u8) ?[]u8 {
    const argv = [_][]const u8{ bin, "--version" };
    const r = std.process.run(gpa, io, .{
        .argv = &argv,
        .environ_map = env,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch |e| {
        if (isSpawnMissing(e)) return null;
        return gpa.dupe(u8, bin) catch null;
    };
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return gpa.dupe(u8, bin) catch null;
}

/// Probe ONE dependency. gpa-owned strings; caller frees version+hint (name is a static literal). A missing
/// binary is a normal answer, never an error, and NOTHING is installed, downloaded, or mutated.
pub fn probe(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) Dep {
    if (std.mem.eql(u8, name, "browser")) return probeBrowser(gpa, io, env);

    const spec = specFor(name) orelse return .{ .name = name, .present = false, .version = "", .hint = "" };
    const bin = if (builtin.os.tag == .windows) spec.win_bin else spec.nix_bin;

    // 1) an explicit override wins when it points at a real file (the operator's escape hatch).
    if (spec.env_override.len > 0) {
        if (env.get(spec.env_override)) |ov| {
            if (ov.len > 0 and fileExists(io, ov))
                return .{ .name = spec.key, .present = true, .version = versionOf(gpa, io, env, ov), .hint = "" };
        }
    }
    // 2) resolve on PATH.
    if (onPath(gpa, io, env, bin)) |path| {
        defer gpa.free(path);
        return .{ .name = spec.key, .present = true, .version = versionOf(gpa, io, env, bin), .hint = "" };
    }
    // 3) absent — the actionable message is the whole point of the feature.
    return .{ .name = spec.key, .present = false, .version = "", .hint = gpa.dupe(u8, spec.remedy) catch "" };
}

/// Browser probe: REUSE launch.discover() (NL_BROWSER_BIN → known Edge/Chrome paths → registry) so there is
/// exactly one place a browser is found. present = discovery returned a path.
fn probeBrowser(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Dep {
    if (launch.discover(gpa, io, env)) |path| {
        defer gpa.free(path);
        // NEVER run `<browser> --version` here. On Windows `msedge.exe --version` does not reliably print a
        // version — it can OPEN A BROWSER WINDOW (observed: the health probe launched Edge). Presence already
        // comes from discover()'s path check, so report the executable's basename (msedge.exe / chrome.exe)
        // as the identity instead: informative about WHICH browser was found, and it launches nothing.
        const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
        const base = if (slash) |i| path[i + 1 ..] else path;
        return .{ .name = "browser", .present = true, .version = gpa.dupe(u8, base) catch "", .hint = "" };
    } else |_| {
        return .{ .name = "browser", .present = false, .version = "", .hint = gpa.dupe(u8, browser_remedy) catch "" };
    }
}

/// Probe the standard set for the health surface. Caller owns the slice + each Dep's version+hint strings.
pub fn probeAll(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) []Dep {
    const out = gpa.alloc(Dep, standard.len) catch return &.{};
    for (standard, 0..) |nm, i| out[i] = probe(gpa, io, env, nm);
    return out;
}

/// The remediation string for `name` WITHOUT probing — for a spawn site that ALREADY tried to run the
/// binary, caught a spawn-missing error (see isSpawnMissing), and only needs the actionable message. Same
/// text probe() returns for an absent dep. gpa-owned (caller frees); "" for an unknown name.
pub fn hint(gpa: std.mem.Allocator, name: []const u8) []u8 {
    if (std.mem.eql(u8, name, "browser")) return gpa.dupe(u8, browser_remedy) catch "";
    const spec = specFor(name) orelse return "";
    return gpa.dupe(u8, spec.remedy) catch "";
}

test "isSpawnMissing splits missing-binary from ran-and-failed" {
    // The binary-missing / could-not-start class earns a hint.
    try std.testing.expect(isSpawnMissing(error.FileNotFound));
    try std.testing.expect(isSpawnMissing(error.InvalidExe));
    try std.testing.expect(isSpawnMissing(error.AccessDenied));
    // A program that RAN (too much output / hung) or an internal failure does NOT.
    try std.testing.expect(!isSpawnMissing(error.StreamTooLong));
    try std.testing.expect(!isSpawnMissing(error.OutOfMemory));
    try std.testing.expect(!isSpawnMissing(error.Timeout));
}

test "hint is specific and actionable for every standard dep" {
    const gpa = std.testing.allocator;
    for (standard) |nm| {
        const h = hint(gpa, nm);
        defer gpa.free(h);
        try std.testing.expect(h.len > 0);
        // every hint must name the env override so there is always an escape hatch
        try std.testing.expect(std.mem.indexOf(u8, h, "NL_") != null);
    }
    const unknown = hint(gpa, "rustc");
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
}
