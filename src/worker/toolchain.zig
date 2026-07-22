//! PROJECT-TOOLCHAIN FLOOR — engine-side dependency bootstrap + manifest-derived acceptance rows.
//!
//! Two long-standing gaps in real multi-file builds, both closed from the project's OWN files (never a
//! goal taxonomy — behavior derives from what the deliverable itself declares):
//!
//!   1. BOOTSTRAP: the swarm writes a package.json / requirements.txt / Cargo.toml / go.mod, and then its
//!      own tests fail on a bare host because nothing ever ran the install step. The engine now runs the
//!      canonical install command for each manifest the deliverable carries, once per manifest change
//!      (content-fingerprinted), gated on live+internet+no-egress-allowlist and the swarm manifest's
//!      `bootstrap` flag.
//!
//!   2. DERIVED CHECKS: with no operator-declared VERIFY rows, a non-Python deliverable had no tier-1 gate
//!      at all — "100% coverage" with nothing ever shown to compile. When the operator declared nothing,
//!      the engine adopts rows from the project's own manifest: npm scripts (only the ones package.json
//!      actually declares), `cargo build`, `go build ./...`, `zig build`. They run through the SAME
//!      declared-checks lane (240s rows, harness-vs-code split), so a missing toolchain is excluded from
//!      the denominator instead of pinning the score.
//!
//! deps.zig stays a pure detect+instruct probe; everything that MUTATES a workdir lives here, explicit.

const std = @import("std");
const builtin = @import("builtin");

fn readSmall(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, name: []const u8, cap: usize) ?[]u8 {
    const p = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch return null;
    defer gpa.free(p);
    return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(cap)) catch null;
}

/// The files whose CONTENT decides whether dependencies must be (re)installed.
const dep_manifests = [_][]const u8{ "package.json", "package-lock.json", "requirements.txt", "Cargo.toml", "Cargo.lock", "go.mod", "go.sum" };

/// Content fingerprint over every dependency manifest present in the workdir; 0 = none exist. A changed
/// fingerprint is the signal to bootstrap again (a mind added a dependency mid-run).
pub fn manifestFingerprint(io: std.Io, gpa: std.mem.Allocator, workdir: []const u8) u64 {
    var h: u64 = 0;
    for (dep_manifests) |mf| {
        const body = readSmall(io, gpa, workdir, mf, 1 << 20) orelse continue;
        defer gpa.free(body);
        h ^= std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, mf), body);
    }
    return h;
}

const InstallStep = struct { present_file: []const u8, label: []const u8, win: []const u8, nix: []const u8 };

/// One canonical install per ecosystem. `npm ci` needs a lockfile; the plain install covers the rest.
/// Ordered: a fullstack workdir runs each applicable step.
const steps = [_]InstallStep{
    .{ .present_file = "package-lock.json", .label = "npm ci", .win = "npm ci --no-audit --no-fund --loglevel=error", .nix = "npm ci --no-audit --no-fund --loglevel=error" },
    .{ .present_file = "package.json", .label = "npm install", .win = "npm install --no-audit --no-fund --loglevel=error", .nix = "npm install --no-audit --no-fund --loglevel=error" },
    .{ .present_file = "requirements.txt", .label = "pip install", .win = "python -m pip install -r requirements.txt --quiet --disable-pip-version-check", .nix = "python3 -m pip install -r requirements.txt --quiet --disable-pip-version-check" },
    .{ .present_file = "Cargo.toml", .label = "cargo fetch", .win = "cargo fetch --quiet", .nix = "cargo fetch --quiet" },
    .{ .present_file = "go.mod", .label = "go mod download", .win = "go mod download", .nix = "go mod download" },
};

fn fileIn(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const p = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch return false;
    defer gpa.free(p);
    if (std.Io.Dir.cwd().access(io, p, .{})) |_| return true else |_| return false;
}

/// Install every dependency set the deliverable declares. Returns a gpa-owned human note describing what
/// ran ("" when no manifest exists). API credentials are blanked from the child env exactly like the
/// declared-checks lane — an install script must never see the operator's keys.
pub fn bootstrap(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, workdir: []const u8) []u8 {
    var note: std.ArrayListUnmanaged(u8) = .empty;
    defer note.deinit(gpa);
    var env = environ.clone(gpa) catch return dupe(gpa, "");
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    var ran_npm = false;
    for (steps) |s| {
        if (!fileIn(io, gpa, workdir, s.present_file)) continue;
        // package-lock implies package.json — run `npm ci` OR `npm install`, never both
        if (std.mem.startsWith(u8, s.label, "npm")) {
            if (ran_npm) continue;
            ran_npm = true;
        }
        const cmd = if (builtin.os.tag == .windows) s.win else s.nix;
        const argv: [3][]const u8 = if (builtin.os.tag == .windows) .{ "cmd", "/C", cmd } else .{ "/bin/sh", "-c", cmd };
        const r = std.process.run(gpa, io, .{ .argv = &argv, .cwd = .{ .path = workdir }, .environ_map = &env, .stdout_limit = .limited(32 << 10), .stderr_limit = .limited(32 << 10), .timeout = .{ .duration = .{ .raw = .fromSeconds(360), .clock = .awake } } }) catch {
            note.print(gpa, "{s}: did not finish (spawn failed or exceeded 360s)\n", .{s.label}) catch {};
            continue;
        };
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        const code: u32 = switch (r.term) {
            .exited => |c| c,
            else => 999,
        };
        if (code == 0) {
            note.print(gpa, "{s}: ok\n", .{s.label}) catch {};
        } else {
            const diag = std.mem.trim(u8, if (std.mem.trim(u8, r.stderr, " \r\n\t").len > 0) r.stderr else r.stdout, " \r\n\t");
            const tail = if (diag.len > 300) diag[diag.len - 300 ..] else diag;
            note.print(gpa, "{s}: FAILED (exit {d}) — {s}\n", .{ s.label, code, tail }) catch {};
        }
    }
    if (note.items.len == 0) return dupe(gpa, "");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "dependency bootstrap (the deliverable's own manifests): ") catch {};
    out.appendSlice(gpa, std.mem.trimEnd(u8, note.items, "\n")) catch {};
    return dupe(gpa, out.items);
}

/// Tier-1 acceptance rows derived from what the project ITSELF declares, newline-separated in the exact
/// shape the declared-checks lane runs. "" when the workdir declares nothing recognizable (a Python
/// deliverable stays on the engine benchmark, which already covers it).
pub fn deriveChecks(gpa: std.mem.Allocator, io: std.Io, workdir: []const u8) []u8 {
    var rows: std.ArrayListUnmanaged(u8) = .empty;
    defer rows.deinit(gpa);
    if (readSmall(io, gpa, workdir, "package.json", 256 << 10)) |pj| {
        defer gpa.free(pj);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, pj, .{}) catch null;
        if (parsed) |pv| {
            defer pv.deinit();
            if (pv.value == .object) if (pv.value.object.get("scripts")) |scripts| if (scripts == .object) {
                if (scripts.object.get("build")) |b| if (b == .string and b.string.len > 0)
                    rows.appendSlice(gpa, "npm run build --silent\n") catch {};
                if (scripts.object.get("test")) |tv| if (tv == .string and tv.string.len > 0 and std.mem.indexOf(u8, tv.string, "no test specified") == null)
                    rows.appendSlice(gpa, "npm test --silent\n") catch {};
            };
        }
    }
    if (fileIn(io, gpa, workdir, "Cargo.toml")) rows.appendSlice(gpa, "cargo build --quiet\n") catch {};
    if (fileIn(io, gpa, workdir, "go.mod")) rows.appendSlice(gpa, "go build ./...\n") catch {};
    if (fileIn(io, gpa, workdir, "build.zig")) rows.appendSlice(gpa, "zig build\n") catch {};
    if (rows.items.len == 0) return dupe(gpa, "");
    return dupe(gpa, std.mem.trimEnd(u8, rows.items, "\n"));
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("");
}

// ------------------------------------------------------------------------------------------- tests

test "deriveChecks adopts only what the project declares" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [64]u8 = undefined;
    const wd = std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
    // nothing declared → no rows
    const none = deriveChecks(gpa, io, wd);
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    // a package.json with a real test script + a Cargo.toml → both rows, npm placeholder skipped
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"scripts\":{\"test\":\"node test.js\",\"build\":\"tsc\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Cargo.toml", .data = "[package]\nname=\"x\"\n" });
    const rows = deriveChecks(gpa, io, wd);
    defer gpa.free(rows);
    try std.testing.expect(std.mem.indexOf(u8, rows, "npm test --silent") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "npm run build --silent") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "cargo build --quiet") != null);
    // the npm default placeholder is NOT a test suite
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{\"scripts\":{\"test\":\"echo \\\"Error: no test specified\\\" && exit 1\"}}" });
    const rows2 = deriveChecks(gpa, io, wd);
    defer gpa.free(rows2);
    try std.testing.expect(std.mem.indexOf(u8, rows2, "npm test") == null);
}

test "manifestFingerprint changes with manifest content and is 0 for a bare dir" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [64]u8 = undefined;
    const wd = std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
    try std.testing.expectEqual(@as(u64, 0), manifestFingerprint(io, gpa, wd));
    try tmp.dir.writeFile(io, .{ .sub_path = "requirements.txt", .data = "flask\n" });
    const a = manifestFingerprint(io, gpa, wd);
    try std.testing.expect(a != 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "requirements.txt", .data = "flask\nrequests\n" });
    const b = manifestFingerprint(io, gpa, wd);
    try std.testing.expect(b != 0 and b != a);
}
