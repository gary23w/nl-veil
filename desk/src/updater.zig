//! Release updates for the merged desktop. GitHub HTTPS + digest-verified native assets; no Git,
//! archive extraction, package manager or installer runtime. A copy of the current executable waits
//! for shutdown, replaces the app/engine together, and restores both on an installation error.
const std = @import("std");
const builtin = @import("builtin");
const nap = @import("nap.zig");
const Io = std.Io;
const dir = Io.Dir;
const windows = builtin.os.tag == .windows;
const exe = if (windows) "veil.exe" else "veil";
const neuron = if (windows) "neuron.exe" else "neuron";
const helper = if (windows) "helper.exe" else "helper";
const staged_app = if (windows) "app.exe" else "app";
const repo = "https://github.com/gary23w/nl-veil/releases/download/";
const limit = 512 * 1024 * 1024;
pub const Phase = enum(u8) { disabled, checking, current, available, installing, restart, failed };
pub var phase = std.atomic.Value(Phase).init(.disabled);
var thread: ?std.Thread = null;
var context: struct { io: Io, gpa: std.mem.Allocator, version: []const u8, args: []const []const u8 } = undefined;
var failure: []const u8 = "";
var release_json: ?[]u8 = null;

pub fn status() []const u8 {
    return switch (phase.load(.acquire)) {
        .disabled => "Updates require an official installed bundle.",
        .checking => "Checking GitHub releases...",
        .current => "You have the latest stable release.",
        .available => "A new release is available. Updating restarts the app; finish active work first.",
        .installing => "Downloading and verifying the update...",
        .restart => "Restarting to install the verified update...",
        .failed => failure,
    };
}

pub fn configure(io: Io, gpa: std.mem.Allocator, version: []const u8, args: []const []const u8) void {
    context = .{ .io = io, .gpa = gpa, .version = version, .args = args };
}

pub fn start() void {
    if (phase.load(.acquire) != .disabled) return;
    var b: [4096]u8 = undefined;
    const n = std.process.executablePath(context.io, &b) catch return;
    if (!std.mem.eql(u8, std.fs.path.basename(b[0..n]), exe)) return;
    const root = std.fs.path.dirname(b[0..n]) orelse return;
    const marker = std.fmt.allocPrint(context.gpa, "{s}/veil-install.txt", .{root}) catch return;
    defer context.gpa.free(marker);
    const raw = dir.cwd().readFileAlloc(context.io, marker, context.gpa, .limited(64)) catch return;
    defer context.gpa.free(raw);
    if (!std.mem.eql(u8, std.mem.trim(u8, raw, "\r\n"), "veil-bundle-v1")) return;
    launch(false);
}

pub fn finish() void {
    if (thread) |th| th.join();
    thread = null;
    if (release_json) |raw| context.gpa.free(raw);
    release_json = null;
}

pub fn launch(install: bool) void {
    const p = phase.load(.acquire);
    if (p == .checking or p == .installing or p == .restart) return;
    if (install and p != .available) return;
    if (thread) |th| th.join();
    thread = null;
    phase.store(if (install) .installing else .checking, .release);
    thread = std.Thread.spawn(.{}, work, .{install}) catch {
        failure = "Could not start the update worker.";
        phase.store(.failed, .release);
        return;
    };
}

const Asset = struct { name: []const u8, browser_download_url: []const u8, size: u64, digest: ?[]const u8 = null };
const Release = struct { tag_name: []const u8, draft: bool, prerelease: bool, assets: []const Asset };

fn stable(tag: []const u8) !std.SemanticVersion {
    const v = try std.SemanticVersion.parse(if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag);
    if (v.pre != null or v.build != null) return error.NotStableRelease;
    return v;
}

fn platform() ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => if (builtin.cpu.arch == .x86_64) "windows-x86_64" else error.UnsupportedPlatform,
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            .x86_64 => "macos-x86_64",
            else => error.UnsupportedPlatform,
        },
        .linux => if (builtin.cpu.arch == .x86_64) "linux-x86_64" else error.UnsupportedPlatform,
        else => error.UnsupportedPlatform,
    };
}

fn select(a: std.mem.Allocator, rel: Release, component: []const u8) !Asset {
    const name = try std.fmt.allocPrint(a, "veil-update-{s}-{s}-{s}", .{ rel.tag_name, try platform(), component });
    defer a.free(name);
    const url = try std.fmt.allocPrint(a, repo ++ "{s}/{s}", .{ rel.tag_name, name });
    defer a.free(url);
    var found: ?Asset = null;
    for (rel.assets) |asset| {
        if (!std.mem.eql(u8, asset.name, name)) continue;
        if (found != null or !std.mem.eql(u8, asset.browser_download_url, url)) return error.InvalidReleaseAsset;
        const digest = asset.digest orelse return error.MissingReleaseDigest;
        if (asset.size == 0 or asset.size > limit or digest.len != 71 or !std.mem.startsWith(u8, digest, "sha256:")) return error.InvalidReleaseAsset;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, digest[7..]) catch return error.InvalidReleaseDigest;
        found = asset;
    }
    return found orelse error.PlatformUpdateNotPublished;
}

fn command(io: Io, a: std.mem.Allocator, argv: []const []const u8, seconds: u32) ![]u8 {
    const r = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(2 << 20), .stderr_limit = .limited(4096), .timeout = .{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } } });
    defer a.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) {
        a.free(r.stdout);
        return error.DownloadOrProcessFailed;
    }
    return r.stdout;
}

fn download(io: Io, a: std.mem.Allocator, url: []const u8, path: []const u8) !void {
    const raw = try command(io, a, &.{ if (windows) "curl.exe" else "curl", "--disable", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "300", "--max-filesize", "536870912", "--output", path, url }, 310);
    a.free(raw);
}

fn verify(io: Io, path: []const u8, asset: Asset) !void {
    const digest = asset.digest orelse return error.MissingReleaseDigest;
    if (digest.len != 71 or !std.mem.startsWith(u8, digest, "sha256:")) return error.InvalidReleaseDigest;
    const file = try dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind != .file or st.size != asset.size) return error.WrongDownloadSize;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositional(io, &.{&buf}, offset);
        if (n == 0) break;
        hash.update(buf[0..n]);
        offset += n;
    }
    var got: [32]u8 = undefined;
    hash.final(&got);
    const hex = std.fmt.bytesToHex(got, .lower);
    if (!std.ascii.eqlIgnoreCase(&hex, digest[7..])) return error.ChecksumMismatch;
}

fn work(install: bool) void {
    perform(install) catch |err| {
        failure = switch (@as(anyerror, err)) {
            error.PlatformUpdateNotPublished, error.MissingReleaseDigest => "Release files are still being published. Check again later.",
            error.DownloadOrProcessFailed => "Could not reach GitHub. Check your connection, proxy and curl installation; retry.",
            error.AccessDenied => "The app folder is not writable. Move the full bundle to a folder you own and retry.",
            error.UpdateAlreadyRunning => "Another update is running, or an interrupted update needs recovery. See docs/UPDATES.md.",
            error.UpdateHelperNotReady, error.CannotStartUpdateHelper => "The update helper could not start. Check OS application approval; the current app is unchanged.",
            error.ChecksumMismatch, error.WrongDownloadSize => "Update verification failed. The current app is unchanged; retry the download.",
            else => @errorName(err),
        };
        phase.store(.failed, .release);
    };
}

fn perform(install: bool) !void {
    const a = context.gpa;
    const io = context.io;
    if (!install) {
        if (release_json) |raw| a.free(raw);
        release_json = null;
        release_json = try command(io, a, &.{ if (windows) "curl.exe" else "curl", "--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--connect-timeout", "10", "--max-time", "20", "--user-agent", "nl-veil-updater", "https://api.github.com/repos/gary23w/nl-veil/releases/latest" }, 25);
    }
    const parsed = try std.json.parseFromSlice(Release, a, release_json orelse return error.NoRelease, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const rel = parsed.value;
    if (rel.draft or rel.prerelease) return error.NotStableRelease;
    const next = try stable(rel.tag_name);
    const current = try std.SemanticVersion.parse(context.version);
    if (next.order(current) != .gt) {
        phase.store(.current, .release);
        return;
    }
    const app_asset = try select(a, rel, "app");
    const engine_asset = try select(a, rel, "neuron");
    if (!install) {
        phase.store(.available, .release);
        return;
    }
    var eb: [4096]u8 = undefined;
    const en = try std.process.executablePath(io, &eb);
    const root = std.fs.path.dirname(eb[0..en]) orelse return error.InvalidInstallPath;
    const lock = try std.fmt.allocPrint(a, "{s}/.veil-update-lock", .{root});
    defer a.free(lock);
    dir.cwd().createDir(io, lock, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) return error.UpdateAlreadyRunning;
        return err;
    };
    var handed_off = false;
    defer if (!handed_off) dir.cwd().deleteDir(io, lock) catch {};
    var random: [8]u8 = undefined;
    io.random(&random);
    const stage = try std.fmt.allocPrint(a, "{s}/.veil-update-{s}", .{ root, std.fmt.bytesToHex(random, .lower) });
    defer a.free(stage);
    try dir.cwd().createDir(io, stage, .default_dir);
    // Failed staging is disposable, but never delete a directory once the helper owns it.
    defer if (!handed_off) dir.cwd().deleteTree(io, stage) catch {};
    const app_path = try std.fmt.allocPrint(a, "{s}/" ++ staged_app, .{stage});
    defer a.free(app_path);
    const engine_path = try std.fmt.allocPrint(a, "{s}/neuron", .{stage});
    defer a.free(engine_path);
    try download(io, a, app_asset.browser_download_url, app_path);
    try verify(io, app_path, app_asset);
    try download(io, a, engine_asset.browser_download_url, engine_path);
    try verify(io, engine_path, engine_asset);
    const hp = try std.fmt.allocPrint(a, "{s}/" ++ helper, .{stage});
    defer a.free(hp);
    try dir.cwd().copyFile(eb[0..en], dir.cwd(), hp, io, .{});
    if (!windows) {
        const out = try command(io, a, &.{ "chmod", "700", hp, app_path, engine_path }, 10);
        a.free(out);
    }
    const built_version = try command(io, a, &.{ app_path, "--build-version" }, 15);
    defer a.free(built_version);
    const actual = try stable(std.mem.trim(u8, built_version, " \r\n"));
    if (actual.order(next) != .eq) return error.ReleaseVersionMismatch;
    var cwd: [4096]u8 = undefined;
    const cwdn = try dir.cwd().realPath(io, &cwd);
    const plan = Plan{ .app = app_asset, .engine = engine_asset, .args = context.args, .cwd = cwd[0..cwdn] };
    const json = try std.json.Stringify.valueAlloc(a, plan, .{});
    defer a.free(json);
    const pp = try std.fmt.allocPrint(a, "{s}/plan.json", .{stage});
    defer a.free(pp);
    try dir.cwd().writeFile(io, .{ .sub_path = pp, .data = json });
    try spawnHelper(io, a, hp);
    handed_off = true;
    const ready = try std.fmt.allocPrint(a, "{s}/ready", .{stage});
    defer a.free(ready);
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (dir.cwd().openFile(io, ready, .{})) |f| {
            f.close(io);
            phase.store(.restart, .release);
            return;
        } else |_| {}
        nap.ms(100);
    }
    return error.UpdateHelperNotReady;
}

const Plan = struct { app: Asset, engine: Asset, args: []const []const u8, cwd: []const u8 };
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(u32, c_int, u32) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(std.os.windows.HANDLE, u32) callconv(.winapi) u32;
extern "c" fn getpid() c_int;
extern "c" fn kill(c_int, c_int) c_int;

fn spawnHelper(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const pid: u32 = if (windows) GetCurrentProcessId() else @intCast(getpid());
    const ps = try std.fmt.allocPrint(a, "{d}", .{pid});
    defer a.free(ps);
    if (windows) {
        const w = std.os.windows;
        const cmd = try std.fmt.allocPrint(a, "\"{s}\" --veil-apply-update {s}", .{ path, ps });
        defer a.free(cmd);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, cmd);
        defer a.free(wide);
        var si = std.mem.zeroes(w.STARTUPINFOW);
        si.cb = @sizeOf(w.STARTUPINFOW);
        var pi: w.PROCESS.INFORMATION = undefined;
        if (w.kernel32.CreateProcessW(null, wide, null, null, .FALSE, @bitCast(@as(u32, 0x09000000)), null, null, &si, &pi) == .FALSE) return error.CannotStartUpdateHelper;
        w.CloseHandle(pi.hThread);
        w.CloseHandle(pi.hProcess);
    } else {
        _ = try std.process.spawn(io, .{ .argv = &.{ path, "--veil-apply-update", ps }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    }
}

/// Called before app initialization or joining the Windows job. No network or server is started.
pub fn apply(io: Io, a: std.mem.Allocator, pid_text: []const u8) !void {
    const pid = try std.fmt.parseInt(u32, pid_text, 10);
    if (pid == 0 or pid > std.math.maxInt(i32)) return error.InvalidParent;
    var eb: [4096]u8 = undefined;
    const en = try std.process.executablePath(io, &eb);
    if (!std.mem.eql(u8, std.fs.path.basename(eb[0..en]), helper)) return error.NotUpdateHelper;
    const stage = std.fs.path.dirname(eb[0..en]) orelse return error.InvalidInstallPath;
    if (!std.mem.startsWith(u8, std.fs.path.basename(stage), ".veil-update-")) return error.InvalidInstallPath;
    const root = std.fs.path.dirname(stage) orelse return error.InvalidInstallPath;
    const lock = try std.fmt.allocPrint(a, "{s}/.veil-update-lock", .{root});
    defer a.free(lock);
    defer dir.cwd().deleteDir(io, lock) catch {};
    const pp = try std.fmt.allocPrint(a, "{s}/plan.json", .{stage});
    defer a.free(pp);
    const raw = try dir.cwd().readFileAlloc(io, pp, a, .limited(2 << 20));
    defer a.free(raw);
    const parsed = try std.json.parseFromSlice(Plan, a, raw, .{});
    defer parsed.deinit();
    const ready = try std.fmt.allocPrint(a, "{s}/ready", .{stage});
    defer a.free(ready);
    if (windows) {
        const handle = OpenProcess(0x00100000, 0, pid) orelse return error.CannotWaitForParent;
        defer std.os.windows.CloseHandle(handle);
        try dir.cwd().writeFile(io, .{ .sub_path = ready, .data = "ready" });
        if (WaitForSingleObject(handle, 120000) != 0) return error.ParentDidNotExit;
    } else {
        try dir.cwd().writeFile(io, .{ .sub_path = ready, .data = "ready" });
        var waited: u32 = 0;
        while (kill(@intCast(pid), 0) == 0 and waited < 120) : (waited += 1) nap.ms(1000);
        if (waited == 120) return error.ParentDidNotExit;
    }
    installPair(io, a, root, stage, parsed.value) catch |err| {
        const logp = try std.fmt.allocPrint(a, "{s}/update-error.txt", .{root});
        defer a.free(logp);
        dir.cwd().writeFile(io, .{ .sub_path = logp, .data = @errorName(err) }) catch {};
        // Never start a mixed pair if filesystem recovery itself failed.
        if (err != error.RollbackFailed) try restart(io, a, root, parsed.value);
        return err;
    };
    restart(io, a, root, parsed.value) catch |err| {
        try rollbackInstalled(io, a, root, stage);
        try restart(io, a, root, parsed.value);
        return err;
    };
}

fn restart(io: Io, a: std.mem.Allocator, root: []const u8, plan: Plan) !void {
    const path = try std.fmt.allocPrint(a, "{s}/" ++ exe, .{root});
    defer a.free(path);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.append(a, path);
    try args.appendSlice(a, plan.args);
    _ = try std.process.spawn(io, .{ .argv = args.items, .cwd = .{ .path = plan.cwd }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = windows });
}

fn installPair(io: Io, a: std.mem.Allocator, root: []const u8, stage: []const u8, plan: Plan) !void {
    const paths = try pairPaths(a, root, stage);
    defer for (paths) |p| a.free(p);
    try verify(io, paths[2], plan.app);
    try verify(io, paths[3], plan.engine);
    try dir.cwd().rename(paths[0], dir.cwd(), paths[4], io);
    dir.cwd().rename(paths[1], dir.cwd(), paths[5], io) catch |err| {
        dir.cwd().rename(paths[4], dir.cwd(), paths[0], io) catch return error.RollbackFailed;
        return err;
    };
    dir.cwd().rename(paths[2], dir.cwd(), paths[0], io) catch |err| {
        dir.cwd().rename(paths[5], dir.cwd(), paths[1], io) catch return error.RollbackFailed;
        dir.cwd().rename(paths[4], dir.cwd(), paths[0], io) catch return error.RollbackFailed;
        return err;
    };
    dir.cwd().rename(paths[3], dir.cwd(), paths[1], io) catch |err| {
        dir.cwd().rename(paths[0], dir.cwd(), paths[2], io) catch return error.RollbackFailed;
        dir.cwd().rename(paths[5], dir.cwd(), paths[1], io) catch return error.RollbackFailed;
        dir.cwd().rename(paths[4], dir.cwd(), paths[0], io) catch return error.RollbackFailed;
        return err;
    };
    // Backups remain alongside the helper for recovery. User data and configuration are never moved.
}

fn pairPaths(a: std.mem.Allocator, root: []const u8, stage: []const u8) ![6][]u8 {
    var paths: [6][]u8 = undefined;
    var count: usize = 0;
    errdefer for (paths[0..count]) |p| a.free(p);
    const bases = [_][]const u8{ root, root, stage, stage, stage, stage };
    const names = [_][]const u8{ exe, "bin/" ++ neuron, staged_app, "neuron", "old-app", "old-neuron" };
    for (bases, names) |base, name| {
        paths[count] = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, name });
        count += 1;
    }
    return paths;
}

fn rollbackInstalled(io: Io, a: std.mem.Allocator, root: []const u8, stage: []const u8) !void {
    const paths = try pairPaths(a, root, stage);
    defer for (paths) |p| a.free(p);
    dir.cwd().rename(paths[0], dir.cwd(), paths[2], io) catch return error.RollbackFailed;
    dir.cwd().rename(paths[1], dir.cwd(), paths[3], io) catch return error.RollbackFailed;
    dir.cwd().rename(paths[4], dir.cwd(), paths[0], io) catch return error.RollbackFailed;
    dir.cwd().rename(paths[5], dir.cwd(), paths[1], io) catch return error.RollbackFailed;
}

test "stable update ordering rejects auxiliary tags and orders numerically" {
    try std.testing.expectError(error.InvalidVersion, stable("builtin-assets"));
    try std.testing.expectError(error.NotStableRelease, stable("v2.0.0-beta.1"));
    try std.testing.expect((try stable("v1.10.0")).order(try stable("v1.9.0")) == .gt);
}

test "release selection requires exact platform assets and a valid GitHub SHA-256 digest" {
    const a = std.testing.allocator;
    const name = try std.fmt.allocPrint(a, "veil-update-v2.0.0-{s}-app", .{try platform()});
    defer a.free(name);
    const url = try std.fmt.allocPrint(a, repo ++ "v2.0.0/{s}", .{name});
    defer a.free(url);
    var assets = [_]Asset{.{ .name = name, .browser_download_url = url, .size = 42, .digest = "sha256:" ++ "a" ** 64 }};
    const rel = Release{ .tag_name = "v2.0.0", .draft = false, .prerelease = false, .assets = &assets };
    try std.testing.expectEqualStrings(name, (try select(a, rel, "app")).name);
    assets[0].browser_download_url = "https://example.com/app";
    try std.testing.expectError(error.InvalidReleaseAsset, select(a, rel, "app"));
    assets[0].browser_download_url = url;
    assets[0].digest = null;
    try std.testing.expectError(error.MissingReleaseDigest, select(a, rel, "app"));
    assets[0].digest = "sha256:" ++ "z" ** 64;
    try std.testing.expectError(error.InvalidReleaseDigest, select(a, rel, "app"));
    try std.testing.expectError(error.PlatformUpdateNotPublished, select(a, rel, "neuron"));
}

test "replacement preserves user data and a missing engine rolls the app back" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-updater-pair-tmp";
    const stage = root ++ "/stage";
    dir.cwd().deleteTree(io, root) catch {};
    defer dir.cwd().deleteTree(io, root) catch {};
    try dir.cwd().createDirPath(io, stage);
    try dir.cwd().createDirPath(io, root ++ "/bin");
    try dir.cwd().writeFile(io, .{ .sub_path = root ++ "/" ++ exe, .data = "old app" });
    try dir.cwd().writeFile(io, .{ .sub_path = root ++ "/user-data", .data = "keep me" });
    try dir.cwd().writeFile(io, .{ .sub_path = stage ++ "/" ++ staged_app, .data = "new" });
    try dir.cwd().writeFile(io, .{ .sub_path = stage ++ "/neuron", .data = "new" });
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("new", &hash, .{});
    const digest = "sha256:" ++ std.fmt.bytesToHex(hash, .lower);
    const asset = Asset{ .name = "test", .browser_download_url = "", .size = 3, .digest = digest };
    const plan = Plan{ .app = asset, .engine = asset, .args = &.{}, .cwd = root };
    try std.testing.expectError(error.FileNotFound, installPair(io, a, root, stage, plan));
    const old = try dir.cwd().readFileAlloc(io, root ++ "/" ++ exe, a, .limited(32));
    defer a.free(old);
    try std.testing.expectEqualStrings("old app", old);
    try dir.cwd().writeFile(io, .{ .sub_path = root ++ "/bin/" ++ neuron, .data = "old engine" });
    try dir.cwd().writeFile(io, .{ .sub_path = stage ++ "/" ++ staged_app, .data = "bad" });
    try std.testing.expectError(error.ChecksumMismatch, installPair(io, a, root, stage, plan));
    try dir.cwd().writeFile(io, .{ .sub_path = stage ++ "/" ++ staged_app, .data = "new" });
    try installPair(io, a, root, stage, plan);
    const installed = try dir.cwd().readFileAlloc(io, root ++ "/" ++ exe, a, .limited(32));
    defer a.free(installed);
    try std.testing.expectEqualStrings("new", installed);
    const engine = try dir.cwd().readFileAlloc(io, root ++ "/bin/" ++ neuron, a, .limited(32));
    defer a.free(engine);
    try std.testing.expectEqualStrings("new", engine);
    const user = try dir.cwd().readFileAlloc(io, root ++ "/user-data", a, .limited(32));
    defer a.free(user);
    try std.testing.expectEqualStrings("keep me", user);
}
