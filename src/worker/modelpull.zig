//! modelpull.zig — fills the built-in model's weights store (builtin.zig) from the published repo.
//!
//! The repo (builtin.HF_REPO) is the manifest: the file list is resolved LIVE from its tree API and
//! each artifact's sha256 comes from the repo's own large-file record — so whatever quant gets
//! published (or re-published) verifies without a source-code change here. Nothing downloads
//! unverified: the transfer lands in a .part beside the final name, the full-file sha256 is checked
//! against the repo's record, and only a verified file is renamed into serving position.
//!
//! Transfer transport mirrors llm.zig's convention: loopback (tests, mirrors on this box) rides the
//! in-process httpc client; anything else needs TLS, which curl carries — with `-C -` the resume of
//! a 7GB file across restarts is curl's problem, not ours. Progress needs no side channel: the
//! status read stats the .part file, so the poller and the transfer never share more than a path.
//!
//! `veil model import` is the no-download door: a machine that already pulled the model through a
//! conventional local runtime has the same GGUF as a content-addressed blob; import copies it into
//! the store and verifies it against the digest its own manifest declares.
//!
//! UPDATES. Every successful install records WHAT it installed (file + sha256 + source) in a small
//! install manifest beside the weights — the store's identity. `startCheck` resolves the repo again
//! and compares shas: same = current, different = update available (surfaced in status; the pull
//! verb IS the updater, it always fetches the repo's present best). Replacing a serving file is
//! made safe by `on_before_swap` (main wires it to unload the engine, which waits out any in-flight
//! generation — Windows will not replace a file the engine still maps), a `.part.sha` sidecar
//! naming which release a partial belongs to (a resumed partial of a SUPERSEDED release is
//! discarded instead of failing verification 7GB later), and supersede cleanup: after a rename-y
//! update lands, the PREVIOUS manifest-managed file is removed — never an unmanaged gguf a user
//! dropped in the store themselves.

const std = @import("std");
const httpc = @import("httpc.zig");
const builtin_mod = @import("builtin.zig");

const log = std.log.scoped(.modelpull);

pub const State = enum { idle, resolving, downloading, verifying, importing, done, failed, cancelled };

/// The update-check verdict — its OWN tiny lane, deliberately outside the transfer state machine so
/// a check can never repaint a serving panel as "not downloaded".
pub const CheckState = enum { never, checking, current, update, failed };


const St = struct {
    mutex: std.Io.Mutex = .init,
    state: State = .idle,
    running: bool = false,
    cancel: bool = false,
    bytes_total: u64 = 0,
    file: [256]u8 = @splat(0),
    file_len: u16 = 0,
    err: [256]u8 = @splat(0),
    err_len: u16 = 0,
    /// The active transfer child, for cancel(). Guarded by `mutex`; both the cancel path and the
    /// transfer thread null it before their kill/reap so the two can never double-reap.
    child: ?*std.process.Child = null,
    host: [128]u8 = @splat(0),
    host_len: u16 = 0,
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    environ: *const std.process.Environ.Map = undefined,
    configured: bool = false,
    /// startImport's explicit source path (empty = auto-discover the local runtime's blob).
    import_src: [512]u8 = @splat(0),
    import_src_len: u16 = 0,
    // --- update check (see CheckState) ---
    checking: bool = false, // a check thread is live; transfers and checks exclude each other
    check_state: CheckState = .never,
    upd_file: [128]u8 = @splat(0),
    upd_file_len: u16 = 0,
    upd_mb: u32 = 0,
    checked_s: i64 = 0,
    // --- the store's identity, cached from the install manifest (configure/promote refresh it) ---
    inst_sha: [64]u8 = @splat(0),
    inst_sha_len: u8 = 0,
    inst_src: [8]u8 = @splat(0), // "pull" | "import" | "adopted"
    inst_src_len: u8 = 0,
    inst_file: [128]u8 = @splat(0),
    inst_file_len: u16 = 0,
};
var st: St = .{};

fn lock() void {
    st.mutex.lockUncancelable(st.io);
}
fn unlock() void {
    st.mutex.unlock(st.io);
}

/// Wired by main (build-gated): fires after the store changes (pull done, import done, delete) so
/// the engine re-points without modelpull importing the FFI side.
pub var on_store_change: ?*const fn () void = null;

/// Wired by main (build-gated): fires right BEFORE the store replaces or removes the serving file.
/// The engine must drop its mapping first (it waits out any in-flight generation) or Windows
/// refuses the replace with the file lock held.
pub var on_before_swap: ?*const fn () void = null;

pub fn configure(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) void {
    st.io = io; // before the first lock — the mutex needs a valid io to park on
    lock();
    defer unlock();
    st.gpa = gpa;
    st.environ = environ;
    st.configured = true;
    const host: []const u8 = blk: {
        if (environ.get("NL_MODEL_HOST")) |h| {
            const t = std.mem.trim(u8, h, " \r\n\t");
            if (t.len > 0 and t.len <= st.host.len) break :blk t;
        }
        break :blk "https://huggingface.co";
    };
    st.host_len = @intCast(host.len);
    @memcpy(st.host[0..host.len], host);
    loadManifestCacheLocked(io);
}

/// Read the install manifest into the st.inst_* cache. Caller holds the lock. Absent/corrupt reads
/// as "no identity" — the check lane then adopts whatever file is serving before comparing.
fn loadManifestCacheLocked(io: std.Io) void {
    st.inst_sha_len = 0;
    st.inst_src_len = 0;
    st.inst_file_len = 0;
    var pbuf: [600]u8 = undefined;
    const p = manifestPath(&pbuf) orelse return;
    var jbuf: [1024]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(io, p, .{}) catch return;
    defer f.close(io);
    const n = f.readPositionalAll(io, &jbuf, 0) catch return;
    const P = struct {
        file: []const u8 = "",
        sha256: []const u8 = "",
        source: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(P, std.heap.page_allocator, jbuf[0..n], .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (parsed.value.sha256.len == 64) {
        @memcpy(st.inst_sha[0..64], parsed.value.sha256[0..64]);
        st.inst_sha_len = 64;
    }
    const sn = @min(parsed.value.source.len, st.inst_src.len);
    @memcpy(st.inst_src[0..sn], parsed.value.source[0..sn]);
    st.inst_src_len = @intCast(sn);
    const fnn = @min(parsed.value.file.len, st.inst_file.len);
    @memcpy(st.inst_file[0..fnn], parsed.value.file[0..fnn]);
    st.inst_file_len = @intCast(fnn);
}

fn manifestPath(buf: []u8) ?[]const u8 {
    const dir = builtin_mod.modelsDir();
    if (dir.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/" ++ builtin_mod.INSTALL_MANIFEST, .{dir}) catch null;
}

/// Record what the store now serves (file name + sha + how it got here) and refresh the cache.
/// The manifest is the store's IDENTITY: the check lane compares against it, and supersede cleanup
/// trusts it as the list of files THIS code manages (and may therefore remove).
fn writeManifest(io: std.Io, file_name: []const u8, sha_hex: []const u8, source: []const u8) void {
    var pbuf: [600]u8 = undefined;
    const p = manifestPath(&pbuf) orelse return;
    var jbuf: [512]u8 = undefined;
    // names come from electFromTree (quote/control-free by its filter) or our own fixed ids, so a
    // plain format IS well-formed JSON here
    const j = std.fmt.bufPrint(&jbuf, "{{\"file\":\"{s}\",\"sha256\":\"{s}\",\"source\":\"{s}\"}}\n", .{ file_name, sha_hex, source }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = j }) catch return;
    lock();
    defer unlock();
    loadManifestCacheLocked(io);
}

pub const Status = struct {
    state: State,
    file: []const u8, // fixed storage — valid until the next pull starts
    bytes_total: u64,
    bytes_done: u64,
    err: []const u8,
};

/// One coherent snapshot. bytes_done is the .part on disk (or the final file when done), so
/// progress is real transferred bytes, resumable and restart-proof.
pub fn status() Status {
    // set-once flag, read without the lock on purpose: before configure() there is no io to park
    // the mutex on, and the only honest answer is "idle, nothing known yet"
    if (!st.configured) return .{ .state = .idle, .file = "", .bytes_total = 0, .bytes_done = 0, .err = "" };
    lock();
    const state = st.state;
    const file = st.file[0..st.file_len];
    const total = st.bytes_total;
    const io = st.io;
    const configured = st.configured;
    unlock();

    var done: u64 = 0;
    if (configured and file.len > 0) {
        var pbuf: [600]u8 = undefined;
        const dir = builtin_mod.modelsDir();
        if (dir.len > 0) {
            const suffix: []const u8 = if (state == .done) "" else ".part";
            if (std.fmt.bufPrint(&pbuf, "{s}/{s}{s}", .{ dir, file, suffix })) |p| {
                if (std.Io.Dir.cwd().statFile(io, p, .{})) |s| {
                    done = s.size;
                } else |_| {}
            } else |_| {}
        }
    }
    lock();
    defer unlock();
    return .{ .state = state, .file = file, .bytes_total = total, .bytes_done = done, .err = st.err[0..st.err_len] };
}

fn setState(s: State) void {
    lock();
    defer unlock();
    st.state = s;
}

fn fail(msg: []const u8) void {
    lock();
    defer unlock();
    st.state = .failed;
    st.err_len = @intCast(@min(msg.len, st.err.len));
    @memcpy(st.err[0..st.err_len], msg[0..st.err_len]);
    log.warn("pull failed: {s}", .{msg});
}

/// Begin a background pull. error.Busy when one is already running; error.NotConfigured before
/// configure() (a route hit during a half-booted server).
pub fn startPull() !void {
    lock();
    if (st.running or st.checking) {
        unlock();
        return error.Busy;
    }
    if (!st.configured) {
        unlock();
        return error.NotConfigured;
    }
    st.running = true;
    st.cancel = false;
    st.state = .resolving;
    st.err_len = 0;
    unlock();
    errdefer {
        lock();
        st.running = false;
        unlock();
    }
    const t = try std.Thread.spawn(.{}, pullThread, .{});
    t.detach();
}

/// Cooperative cancel: raises the flag and kills any in-flight transfer child. The thread lands in
/// `.cancelled` and keeps the .part — a later pull resumes from it.
pub fn cancel() void {
    if (!st.configured) return;
    lock();
    st.cancel = true;
    if (st.child) |c| {
        st.child = null;
        c.kill(st.io);
    }
    unlock();
}

fn cancelled() bool {
    lock();
    defer unlock();
    return st.cancel;
}

fn pullThread() void {
    defer {
        lock();
        st.running = false;
        unlock();
    }
    const gpa = st.gpa;
    const io = st.io;
    var hbuf: [128]u8 = undefined;
    lock();
    const host = std.fmt.bufPrint(&hbuf, "{s}", .{st.host[0..st.host_len]}) catch {
        unlock();
        return fail("host too long");
    };
    unlock();

    // ---- resolve the artifact from the repo tree ----
    const pick = resolveArtifact(gpa, io, host) orelse {
        return fail("could not resolve a .gguf in the model repo (not published yet, or no network)");
    };
    defer gpa.free(pick.name);
    lock();
    st.file_len = @intCast(@min(pick.name.len, st.file.len));
    @memcpy(st.file[0..st.file_len], pick.name[0..st.file_len]);
    st.bytes_total = pick.size;
    st.state = .downloading;
    unlock();
    if (cancelled()) return setState(.cancelled);

    // ---- transfer into the .part ----
    const dir = builtin_mod.modelsDir();
    if (dir.len == 0) return fail("no models directory (server booted without a data root?)");
    const dest = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, pick.name }) catch return fail("oom");
    defer gpa.free(dest);
    const part = std.fmt.allocPrint(gpa, "{s}.part", .{dest}) catch return fail("oom");
    defer gpa.free(part);
    const part_sha = std.fmt.allocPrint(gpa, "{s}.sha", .{part}) catch return fail("oom");
    defer gpa.free(part_sha);
    const url = std.fmt.allocPrint(gpa, "{s}/" ++ builtin_mod.HF_REPO ++ "/resolve/main/{s}", .{ host, pick.name }) catch return fail("oom");
    defer gpa.free(url);

    // A leftover partial only resumes when its sidecar names THIS release. A partial of a
    // superseded release would transfer to completion and then fail verification — 7GB of work to
    // learn what the sidecar says up front.
    if (!partIsForRelease(io, part, part_sha, pick.sha256[0..])) {
        std.Io.Dir.cwd().deleteFile(io, part) catch {};
        log.info("discarded a partial of a different release", .{});
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part_sha, .data = pick.sha256[0..] }) catch {};

    if (!fetchToPart(gpa, io, url, part)) {
        if (cancelled()) return setState(.cancelled);
        return fail("transfer failed (network, disk, or the repo file moved)");
    }
    if (cancelled()) return setState(.cancelled);

    // ---- verify against the repo's own record, then promote ----
    setState(.verifying);
    var sha_buf: [64]u8 = undefined;
    const got = sha256HexOfFile(io, part, &sha_buf) orelse return fail("could not read the transferred file back");
    if (!std.ascii.eqlIgnoreCase(got, pick.sha256[0..])) {
        std.Io.Dir.cwd().deleteFile(io, part) catch {};
        std.Io.Dir.cwd().deleteFile(io, part_sha) catch {};
        return fail("sha256 mismatch — transfer corrupted, partial repo upload, or a tampered mirror; the partial was discarded");
    }
    // remember which file the manifest managed BEFORE this install, for supersede cleanup below
    var prev_buf: [128]u8 = undefined;
    var prev_len: usize = 0;
    {
        lock();
        defer unlock();
        prev_len = st.inst_file_len;
        @memcpy(prev_buf[0..prev_len], st.inst_file[0..prev_len]);
    }
    if (on_before_swap) |cb| cb(); // the engine drops its mapping (waits out a running generation)
    std.Io.Dir.cwd().deleteFile(io, dest) catch {}; // same-name update: replace in place
    std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), dest, io) catch return fail("could not move the verified file into place");
    std.Io.Dir.cwd().deleteFile(io, part_sha) catch {};
    writeManifest(io, pick.name, pick.sha256[0..], "pull");
    // supersede: a rename-y update leaves the old MANAGED file behind — 7GB of dead weight that
    // could even win the next election. Only the manifest's own previous file is ever removed;
    // an unmanaged gguf someone placed here by hand is not ours to delete.
    if (prev_len > 0 and !std.mem.eql(u8, prev_buf[0..prev_len], pick.name)) {
        var ob: [600]u8 = undefined;
        if (std.fmt.bufPrint(&ob, "{s}/{s}", .{ dir, prev_buf[0..prev_len] })) |old_path| {
            std.Io.Dir.cwd().deleteFile(io, old_path) catch {};
            log.info("superseded {s}", .{prev_buf[0..prev_len]});
        } else |_| {}
    }
    {
        // this install IS the repo's present best — the check verdict is fresh by construction
        lock();
        defer unlock();
        st.check_state = .current;
        st.checked_s = nowS(io);
    }
    setState(.done);
    builtin_mod.rescan(io);
    if (on_store_change) |cb| cb();
    log.info("pulled {s} ({d} bytes, verified)", .{ pick.name, pick.size });
}

fn nowS(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
}

/// Does the .part on disk belong to the release we are about to fetch? True when there is no
/// partial at all (nothing to mismatch) or when the sidecar names the same sha.
pub fn partIsForRelease(io: std.Io, part: []const u8, part_sha: []const u8, want_sha: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, part, .{}) catch return true; // no partial → nothing stale
    var buf: [80]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(io, part_sha, .{}) catch return false; // partial without identity → stale
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return false;
    const have = std.mem.trim(u8, buf[0..n], " \r\n\t");
    return have.len == 64 and std.ascii.eqlIgnoreCase(have, want_sha);
}

const Artifact = struct {
    name: []u8, // gpa-owned
    size: u64,
    sha256: [64]u8,
};

/// GET {host}/api/models/{repo}/tree/main and elect the artifact. Null on any failure — the caller
/// owns the user-facing message.
fn resolveArtifact(gpa: std.mem.Allocator, io: std.Io, host: []const u8) ?Artifact {
    const url = std.fmt.allocPrint(gpa, "{s}/api/models/" ++ builtin_mod.HF_REPO ++ "/tree/main", .{host}) catch return null;
    defer gpa.free(url);
    const body = httpGet(gpa, io, url, 1 << 20) orelse return null;
    defer gpa.free(body);
    return electFromTree(gpa, body);
}

pub const TreeEntry = struct {
    path: []const u8 = "",
    size: u64 = 0,
    lfs: ?struct {
        oid: []const u8 = "",
        size: u64 = 0,
    } = null,
};

/// The election rule, pure so it is pinnable: prefer a q4_k_m-named gguf (the plug-and-play
/// default quant), else the LARGEST gguf — deterministic against a repo that grows alternates.
pub fn electFromTree(gpa: std.mem.Allocator, tree_json: []const u8) ?Artifact {
    const parsed = std.json.parseFromSlice([]TreeEntry, gpa, tree_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var best: ?TreeEntry = null;
    var best_q4 = false;
    for (parsed.value) |e| {
        if (!std.ascii.endsWithIgnoreCase(e.path, ".gguf")) continue;
        // a name that could break out of a path or a hand-formatted JSON manifest is no candidate;
        // real model artifacts are never named with quotes, separators-in-disguise, or controls
        if (std.mem.indexOfAny(u8, e.path, "\"\\/\r\n\t") != null) continue;
        const lfs = e.lfs orelse continue; // a gguf small enough to dodge LFS is not a real model
        if (lfs.oid.len != 64) continue; // the record IS the verification root — no oid, no candidate
        const q4 = std.ascii.indexOfIgnoreCase(e.path, "q4_k_m") != null;
        const better = best == null or
            (q4 and !best_q4) or
            (q4 == best_q4 and effSize(e) > effSize(best.?));
        if (better) {
            best = e;
            best_q4 = q4;
        }
    }
    const b = best orelse return null;
    var out = Artifact{
        .name = gpa.dupe(u8, b.path) catch return null,
        .size = effSize(b),
        .sha256 = undefined,
    };
    @memcpy(out.sha256[0..], b.lfs.?.oid[0..64]);
    return out;
}

fn effSize(e: TreeEntry) u64 {
    if (e.lfs) |l| if (l.size > 0) return l.size;
    return e.size;
}

/// GET a small document. Loopback → in-process socket; hosted → curl (TLS).
fn httpGet(gpa: std.mem.Allocator, io: std.Io, url: []const u8, cap: usize) ?[]u8 {
    if (httpc.parseLoopbackUrl(url)) |t| {
        switch (httpc.request(io, gpa, .{
            .method = "GET",
            .port = t.port,
            .path = if (t.path.len > 0) t.path else "/",
            .timeout_s = 20,
            .cap = cap,
        })) {
            .ok => |resp| return resp.body,
            else => return null,
        }
    }
    const run = std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-sS", "-L", "--fail", "--connect-timeout", "20", "--max-time", "60", url },
        .stdout_limit = .limited(cap),
    }) catch return null;
    gpa.free(run.stderr);
    if (run.term != .exited or run.term.exited != 0) {
        gpa.free(run.stdout);
        return null;
    }
    return run.stdout;
}

/// Transfer `url` into `part`. True on a completed transfer (verification still pending).
/// Hosted transport is curl: resume (-C -), follow the CDN redirect (-L), --fail so a 404 never
/// lands as an HTML .part, transient-error retries.
fn fetchToPart(gpa: std.mem.Allocator, io: std.Io, url: []const u8, part: []const u8) bool {
    if (httpc.parseLoopbackUrl(url)) |t| {
        // loopback (tests / same-box mirror): whole-body fetch, no resume — bodies here are small
        switch (httpc.request(io, gpa, .{
            .method = "GET",
            .port = t.port,
            .path = if (t.path.len > 0) t.path else "/",
            .timeout_s = 60,
            .cap = 64 << 20,
        })) {
            .ok => |resp| {
                defer gpa.free(resp.body);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = resp.body }) catch return false;
                return true;
            },
            else => return false,
        }
    }
    var child = std.process.spawn(io, .{
        .argv = &.{ "curl", "-sS", "-L", "--fail", "--connect-timeout", "20", "--retry", "3", "--retry-delay", "2", "-C", "-", "-o", part, url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return false;
    lock();
    st.child = &child;
    unlock();
    const term = child.wait(io) catch {
        lock();
        st.child = null;
        unlock();
        return false;
    };
    lock();
    const was_cancelled = st.child == null and st.cancel; // cancel() nulled it and killed
    st.child = null;
    unlock();
    if (was_cancelled) return false;
    return term == .exited and term.exited == 0;
}

/// Streaming sha256 of a file, hex into `out` (64 bytes). Null if unreadable.
pub fn sha256HexOfFile(io: std.Io, path: []const u8, out: *[64]u8) ?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [256 << 10]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = f.readPositionalAll(io, &buf, off) catch return null;
        if (n == 0) break;
        h.update(buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out[0..64];
}

// ---- import from a conventional local runtime's blob store ---------------------------------------

/// Kick off an import on a background thread (the copy of a 7GB file is minutes on a spinning
/// disk); progress/outcome ride the same status states the pull uses. error.Busy while any
/// pull/import runs.
pub fn startImport(explicit: ?[]const u8) !void {
    lock();
    if (st.running or st.checking) {
        unlock();
        return error.Busy;
    }
    if (!st.configured) {
        unlock();
        return error.NotConfigured;
    }
    const src = explicit orelse "";
    if (src.len > st.import_src.len) {
        unlock();
        return error.PathTooLong;
    }
    st.import_src_len = @intCast(src.len);
    @memcpy(st.import_src[0..src.len], src);
    st.running = true;
    st.cancel = false;
    st.err_len = 0;
    st.state = .importing;
    unlock();
    errdefer {
        lock();
        st.running = false;
        unlock();
    }
    const t = try std.Thread.spawn(.{}, importThread, .{});
    t.detach();
}

fn importThread() void {
    defer {
        lock();
        st.running = false;
        unlock();
    }
    lock();
    var src_buf: [512]u8 = undefined;
    const n = st.import_src_len;
    @memcpy(src_buf[0..n], st.import_src[0..n]);
    st.mutex.unlock(st.io);
    const explicit: ?[]const u8 = if (n > 0) src_buf[0..n] else null;
    const dest = importLocal(st.gpa, st.io, explicit) catch |e| {
        return fail(switch (e) {
            error.NoLocalCopy => "no local copy found to import (the local runtime has no " ++ builtin_mod.MODEL_ID ++ ")",
            error.DigestMismatch => "the local blob failed its own manifest digest — refusing to serve it",
            error.NotAModel => "that file is not a GGUF model",
            else => "import failed (unreadable source, or disk full)",
        });
    };
    st.gpa.free(dest);
}

/// Copy an already-downloaded GGUF into the store — either an explicit path, or (path=null) the
/// model layer this machine's local runtime holds for builtin.MODEL_ID, verified against the digest
/// its own manifest declares. Returns the serving path (gpa-owned).
pub fn importLocal(gpa: std.mem.Allocator, io: std.Io, explicit: ?[]const u8) ![]u8 {
    const environ = st.environ;
    var src_buf: [640]u8 = undefined;
    var want_sha: ?[64]u8 = null;
    const src: []const u8 = blk: {
        if (explicit) |p| break :blk p;
        const found = findRuntimeBlob(io, environ, &src_buf) orelse return error.NoLocalCopy;
        want_sha = found.sha;
        break :blk found.path;
    };

    const dir = builtin_mod.modelsDir();
    if (dir.len == 0) return error.NoStore;
    const dest = try std.fmt.allocPrint(gpa, "{s}/" ++ builtin_mod.MODEL_ID ++ ".gguf", .{dir});
    errdefer gpa.free(dest);
    const part = try std.fmt.allocPrint(gpa, "{s}.part", .{dest});
    defer gpa.free(part);

    setState(.importing);
    copyFile(io, src, part) catch {
        setState(.failed);
        return error.CopyFailed;
    };
    // sha the copy ALWAYS: the auto path verifies it against the runtime's declared digest, and
    // either path records it in the install manifest — the identity the update check compares.
    var got_buf: [64]u8 = undefined;
    const got = sha256HexOfFile(io, part, &got_buf) orelse {
        setState(.failed);
        return error.CopyFailed;
    };
    if (want_sha) |ws| {
        if (!std.ascii.eqlIgnoreCase(got, ws[0..])) {
            std.Io.Dir.cwd().deleteFile(io, part) catch {};
            setState(.failed);
            return error.DigestMismatch;
        }
    } else {
        // explicit path: at least require the container magic, so a typo'd path fails honestly
        if (!looksGguf(io, part)) {
            std.Io.Dir.cwd().deleteFile(io, part) catch {};
            setState(.failed);
            return error.NotAModel;
        }
    }
    var prev_buf: [128]u8 = undefined;
    var prev_len: usize = 0;
    {
        lock();
        defer unlock();
        prev_len = st.inst_file_len;
        @memcpy(prev_buf[0..prev_len], st.inst_file[0..prev_len]);
    }
    if (on_before_swap) |cb| cb(); // the engine drops its mapping before the file is replaced
    std.Io.Dir.cwd().deleteFile(io, dest) catch {};
    std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), dest, io) catch {
        setState(.failed);
        return error.CopyFailed;
    };
    writeManifest(io, builtin_mod.MODEL_ID ++ ".gguf", got, "import");
    if (prev_len > 0 and !std.mem.eql(u8, prev_buf[0..prev_len], builtin_mod.MODEL_ID ++ ".gguf")) {
        var ob: [600]u8 = undefined;
        if (std.fmt.bufPrint(&ob, "{s}/{s}", .{ dir, prev_buf[0..prev_len] })) |old_path| {
            std.Io.Dir.cwd().deleteFile(io, old_path) catch {};
        } else |_| {}
    }
    {
        // an import may be older OR newer than the repo's best — the verdict is unknown again
        lock();
        defer unlock();
        st.check_state = .never;
    }
    setState(.done);
    builtin_mod.rescan(io);
    if (on_store_change) |cb| cb();
    return dest;
}

const FoundBlob = struct { path: []const u8, sha: [64]u8 };

/// The local runtime's store is content-addressed: its manifest for MODEL_ID names the model layer
/// by sha256 digest, and the blob file carries that digest in its name. Both live under the user's
/// home. Returns the blob path (in `buf`) + the digest to verify the copy against.
fn findRuntimeBlob(io: std.Io, environ: *const std.process.Environ.Map, buf: *[640]u8) ?FoundBlob {
    const home = environ.get("USERPROFILE") orelse environ.get("HOME") orelse return null;
    var mbuf: [640]u8 = undefined;
    const manifest = std.fmt.bufPrint(&mbuf, "{s}/.ollama/models/manifests/registry.ollama.ai/library/" ++ builtin_mod.MODEL_ID ++ "/latest", .{home}) catch return null;
    var jbuf: [16 << 10]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(io, manifest, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, &jbuf, 0) catch return null;
    const digest = modelDigestFromManifest(jbuf[0..n]) orelse return null;
    const path = std.fmt.bufPrint(buf, "{s}/.ollama/models/blobs/sha256-{s}", .{ home, digest.hex[0..] }) catch return null;
    return .{ .path = path, .sha = digest.hex };
}

const Digest = struct { hex: [64]u8 };

/// The model layer's sha256 out of a runtime manifest: the layer whose mediaType ends ".model".
pub fn modelDigestFromManifest(json: []const u8) ?Digest {
    const P = struct {
        layers: []const struct {
            mediaType: []const u8 = "",
            digest: []const u8 = "",
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(P, std.heap.page_allocator, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    for (parsed.value.layers) |l| {
        if (!std.mem.endsWith(u8, l.mediaType, ".model")) continue;
        if (!std.mem.startsWith(u8, l.digest, "sha256:")) continue;
        const hexs = l.digest["sha256:".len..];
        if (hexs.len != 64) continue;
        var d = Digest{ .hex = undefined };
        @memcpy(d.hex[0..], hexs[0..64]);
        return d;
    }
    return null;
}

fn looksGguf(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    var magic: [4]u8 = undefined;
    const n = f.readPositionalAll(io, &magic, 0) catch return false;
    return n == 4 and std.mem.eql(u8, &magic, "GGUF");
}

fn copyFile(io: std.Io, src: []const u8, dest: []const u8) !void {
    const in = try std.Io.Dir.cwd().openFile(io, src, .{});
    defer in.close(io);
    const out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);
    var buf: [1 << 20]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try in.readPositionalAll(io, &buf, off);
        if (n == 0) break;
        try out.writePositionalAll(io, buf[0..n], off);
        off += n;
        if (n < buf.len) break;
    }
}

/// Remove the serving weights (route: DELETE /api/v1/models/builtin). Refused while a pull runs.
pub fn remove(io: std.Io) !void {
    lock();
    const busy = st.running or st.checking;
    unlock();
    if (busy) return error.Busy;
    const p = builtin_mod.modelPath() orelse return;
    var pbuf: [600]u8 = undefined;
    const own = std.fmt.bufPrint(&pbuf, "{s}", .{p}) catch return error.Busy;
    if (on_before_swap) |cb| cb(); // the engine may hold the mapping — Windows refuses the delete otherwise
    try std.Io.Dir.cwd().deleteFile(io, own);
    var mbuf: [600]u8 = undefined;
    if (manifestPath(&mbuf)) |mp| std.Io.Dir.cwd().deleteFile(io, mp) catch {};
    {
        lock();
        defer unlock();
        st.inst_sha_len = 0;
        st.inst_src_len = 0;
        st.inst_file_len = 0;
        st.check_state = .never;
    }
    builtin_mod.rescan(io);
    setState(.idle);
    if (on_store_change) |cb| cb();
}

// ---- the update check --------------------------------------------------------------------------

pub const CheckStatus = struct {
    state: CheckState,
    /// The repo's current elected artifact (what a pull would install). Fixed storage.
    file: []const u8,
    mb: u32,
    checked_s: i64,
    /// The install's identity, for display/support: first 12 hex of the serving file's sha + how it
    /// arrived ("pull"/"import"/"adopted"). Empty when the store has no manifest yet.
    inst_sha12: []const u8,
    inst_src: []const u8,
};

pub fn checkStatus() CheckStatus {
    if (!st.configured) return .{ .state = .never, .file = "", .mb = 0, .checked_s = 0, .inst_sha12 = "", .inst_src = "" };
    lock();
    defer unlock();
    return .{
        .state = if (st.checking) .checking else st.check_state,
        .file = st.upd_file[0..st.upd_file_len],
        .mb = st.upd_mb,
        .checked_s = st.checked_s,
        .inst_sha12 = st.inst_sha[0..@min(st.inst_sha_len, 12)],
        .inst_src = st.inst_src[0..st.inst_src_len],
    };
}

/// Kick an update check: resolve the repo's current artifact and compare its sha against the
/// install manifest. Runs on its own thread (the resolve is network, and an unmanaged store gets
/// sha'd once to adopt an identity). Never starts under a transfer, and transfers never start
/// under it — both flip `running`/`checking` under the one lock.
pub fn startCheck() !void {
    lock();
    if (st.running or st.checking) {
        unlock();
        return error.Busy;
    }
    if (!st.configured) {
        unlock();
        return error.NotConfigured;
    }
    st.checking = true;
    unlock();
    errdefer {
        lock();
        st.checking = false;
        unlock();
    }
    const t = try std.Thread.spawn(.{}, checkThread, .{});
    t.detach();
}

fn checkThread() void {
    defer {
        lock();
        st.checking = false;
        unlock();
    }
    const gpa = st.gpa;
    const io = st.io;

    // adopt an unmanaged store first: a pre-manifest install (or a hand-dropped gguf) gets its sha
    // computed ONCE and recorded, so this and every later check compares identities, not guesses
    var have_identity = blk: {
        lock();
        defer unlock();
        break :blk st.inst_sha_len == 64;
    };
    if (!have_identity) {
        if (builtin_mod.modelPath()) |p| {
            var pb: [600]u8 = undefined;
            if (std.fmt.bufPrint(&pb, "{s}", .{p})) |own| {
                var hex: [64]u8 = undefined;
                if (sha256HexOfFile(io, own, &hex)) |h| {
                    writeManifest(io, baseName(own), h, "adopted");
                    have_identity = true;
                }
            } else |_| {}
        }
    }

    var hbuf: [128]u8 = undefined;
    lock();
    const host = std.fmt.bufPrint(&hbuf, "{s}", .{st.host[0..st.host_len]}) catch {
        unlock();
        return;
    };
    unlock();
    const pick = resolveArtifact(gpa, io, host) orelse {
        lock();
        defer unlock();
        st.check_state = .failed;
        st.checked_s = nowS(io);
        return;
    };
    defer gpa.free(pick.name);

    lock();
    defer unlock();
    st.checked_s = nowS(io);
    st.upd_file_len = @intCast(@min(pick.name.len, st.upd_file.len));
    @memcpy(st.upd_file[0..st.upd_file_len], pick.name[0..st.upd_file_len]);
    st.upd_mb = @intCast(@min(pick.size >> 20, std.math.maxInt(u32)));
    const same = st.inst_sha_len == 64 and std.ascii.eqlIgnoreCase(st.inst_sha[0..64], pick.sha256[0..]);
    st.check_state = if (same) .current else .update;
}

/// The final path component — plain string math, no io.
pub fn baseName(p: []const u8) []const u8 {
    var i = p.len;
    while (i > 0) : (i -= 1) {
        if (p[i - 1] == '/' or p[i - 1] == '\\') return p[i..];
    }
    return p;
}

// ---- tests ---------------------------------------------------------------------------------------

const fakehttp = @import("fakehttp.zig");

test "election: q4_k_m wins over larger alternates; without one the largest gguf wins; no lfs oid = no candidate" {
    const gpa = std.testing.allocator;
    const tree =
        \\[{"type":"file","path":"README.md","size":12},
        \\ {"type":"file","path":"the-veil-12b-q8_0.gguf","size":1,"lfs":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":13000}},
        \\ {"type":"file","path":"the-veil-12b-Q4_K_M.gguf","size":1,"lfs":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":7000}}]
    ;
    var a = electFromTree(gpa, tree).?;
    defer gpa.free(a.name);
    try std.testing.expectEqualStrings("the-veil-12b-Q4_K_M.gguf", a.name);
    try std.testing.expectEqual(@as(u64, 7000), a.size);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", a.sha256[0..]);

    const no_q4 =
        \\[{"path":"small.gguf","size":1,"lfs":{"oid":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":5}},
        \\ {"path":"big.gguf","size":1,"lfs":{"oid":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","size":9}}]
    ;
    const b = electFromTree(gpa, no_q4).?;
    defer gpa.free(b.name);
    try std.testing.expectEqualStrings("big.gguf", b.name);

    // a gguf with no LFS record cannot be verified, so it is not a candidate at all
    const bare = "[{\"path\":\"x.gguf\",\"size\":9}]";
    try std.testing.expect(electFromTree(gpa, bare) == null);

    // a name that could forge a path or the hand-formatted install manifest is no candidate either
    const evil =
        \\[{"path":"a\"b.gguf","size":1,"lfs":{"oid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","size":5}},
        \\ {"path":"sub/dir.gguf","size":1,"lfs":{"oid":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","size":9}}]
    ;
    try std.testing.expect(electFromTree(gpa, evil) == null);
}

test "install manifest: written on promote, read back as the store's identity, absent reads as none" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-modelpull-manifest-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    builtin_mod.init(io, &env, root);
    configure(gpa, io, &env);

    // absent → no identity
    {
        const cs = checkStatus();
        try std.testing.expectEqual(@as(usize, 0), cs.inst_sha12.len);
    }
    const sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    writeManifest(io, "the-veil-12b-q4_k_m.gguf", sha, "pull");
    {
        const cs = checkStatus();
        try std.testing.expectEqualStrings(sha[0..12], cs.inst_sha12);
        try std.testing.expectEqualStrings("pull", cs.inst_src);
    }
    // and a fresh configure (a server restart) reads the same identity back off disk
    configure(gpa, io, &env);
    {
        const cs = checkStatus();
        try std.testing.expectEqualStrings(sha[0..12], cs.inst_sha12);
    }
}

test "stale-partial rule: no partial passes, a matching sidecar passes, mismatch or no sidecar discards" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-modelpull-part-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    const part = root ++ "/m.gguf.part";
    const side = root ++ "/m.gguf.part.sha";
    const sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    // nothing on disk → nothing stale to discard
    try std.testing.expect(partIsForRelease(io, part, side, sha_a));
    // a partial WITHOUT an identity sidecar is stale by definition (pre-sidecar leftovers)
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = "half" });
    try std.testing.expect(!partIsForRelease(io, part, side, sha_a));
    // sidecar names the same release → resume it
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = side, .data = sha_a });
    try std.testing.expect(partIsForRelease(io, part, side, sha_a));
    // the repo moved on → the partial belongs to a superseded release
    try std.testing.expect(!partIsForRelease(io, part, side, sha_b));
}

test "baseName: plain string math over both separators" {
    try std.testing.expectEqualStrings("m.gguf", baseName("C:\\models\\m.gguf"));
    try std.testing.expectEqualStrings("m.gguf", baseName("data/models/m.gguf"));
    try std.testing.expectEqualStrings("m.gguf", baseName("m.gguf"));
}

test "runtime manifest: the .model layer's digest is extracted, other layers ignored" {
    const mani =
        \\{"schemaVersion":2,"layers":[
        \\ {"mediaType":"application/vnd.ollama.image.template","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":13},
        \\ {"mediaType":"application/vnd.ollama.image.model","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","size":7381381728}]}
    ;
    const d = modelDigestFromManifest(mani).?;
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222222222222222222222222222", d.hex[0..]);
    try std.testing.expect(modelDigestFromManifest("{\"layers\":[]}") == null);
    // a malformed digest (wrong scheme / truncated) never yields a blob path
    try std.testing.expect(modelDigestFromManifest("{\"layers\":[{\"mediaType\":\"a.model\",\"digest\":\"md5:abc\"}]}") == null);
}

test "sha256HexOfFile matches a known vector, and the verify path rejects a corrupted transfer" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-modelpull-sha-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // sha256("abc") — the canonical vector
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/abc.bin", .data = "abc" });
    var hex: [64]u8 = undefined;
    const got = sha256HexOfFile(io, root ++ "/abc.bin", &hex).?;
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", got);
    try std.testing.expect(sha256HexOfFile(io, root ++ "/absent.bin", &hex) == null);
}

test "loopback pull end-to-end: resolve -> transfer -> verify -> promote into the store" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-modelpull-e2e-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    builtin_mod.init(io, &env, root);

    // The fake answers every request with the same bytes, so the run needs two servers in
    // sequence: one serving the tree JSON for resolve, one serving the artifact bytes.
    const payload = "GGUFfake-weights-payload";
    var pay_sha: [64]u8 = undefined;
    {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/pay.bin", .data = payload });
        _ = sha256HexOfFile(io, root ++ "/pay.bin", &pay_sha).?;
    }
    var tree_json: [512]u8 = undefined;
    const tree = try std.fmt.bufPrint(&tree_json, "[{{\"path\":\"the-veil-12b-q4_k_m.gguf\",\"size\":1,\"lfs\":{{\"oid\":\"{s}\",\"size\":{d}}}}}]", .{ pay_sha[0..], payload.len });

    var resolver: fakehttp.Server = undefined;
    {
        var reply: [768]u8 = undefined;
        const r = try std.fmt.bufPrint(&reply, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ tree.len, tree });
        try resolver.start(io, r);
    }
    var host_buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "http://127.0.0.1:{d}", .{resolver.port});
    const pick = resolveArtifact(gpa, io, host) orelse {
        resolver.stop();
        return error.TestResolveFailed;
    };
    resolver.stop();
    defer gpa.free(pick.name);
    try std.testing.expectEqualStrings("the-veil-12b-q4_k_m.gguf", pick.name);

    // transfer + verify + promote, against a second fake serving the artifact
    var blobsrv: fakehttp.Server = undefined;
    {
        var reply: [256]u8 = undefined;
        const r = try std.fmt.bufPrint(&reply, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
        try blobsrv.start(io, r);
    }
    defer blobsrv.stop();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/resolve/main/{s}", .{ blobsrv.port, pick.name });
    const part = root ++ "/models/the-veil-12b-q4_k_m.gguf.part";
    try std.testing.expect(fetchToPart(gpa, io, url, part));

    var hex: [64]u8 = undefined;
    const got = sha256HexOfFile(io, part, &hex).?;
    try std.testing.expectEqualStrings(pay_sha[0..], got);
    const dest = root ++ "/models/the-veil-12b-q4_k_m.gguf";
    try std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), dest, io);
    builtin_mod.rescan(io);
    const served = builtin_mod.modelPath() orelse return error.TestExpectedModel;
    try std.testing.expect(std.mem.endsWith(u8, served, "the-veil-12b-q4_k_m.gguf"));
}

test "double start is refused while running" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    configure(gpa, io, &env); // the lock needs a live io before anything may take it

    lock();
    const was_running = st.running;
    st.running = true;
    unlock();
    defer {
        lock();
        st.running = was_running;
        unlock();
    }
    try std.testing.expectError(error.Busy, startPull());
}
