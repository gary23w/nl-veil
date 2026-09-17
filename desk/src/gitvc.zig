//! gitvc.zig — the chat's VERSION-CONTROL engine: real git + GitHub for the Veil, built for the constraint that
//! matters where nl-veil actually runs: CLASSIC TOKENS ONLY. No SSH, no OAuth device flow, no dependence on the
//! `gh` CLI (any of which are blocked or absent in restricted regions) — just a Personal Access Token over
//! HTTPS, which works anywhere `git` + `curl` do.
//!
//! Keeping the token out of any TRANSMITTED or SHARED surface is the whole point. The PAT here:
//!   * is stored by secrets.zig as PLAINTEXT in the local data dir — this is a local, login-gated app and
//!     nothing is sealed any more (DPAPI survives there only to unseal legacy files one last time). It is
//!     never in settings.json and never in a repo-tracked file, but anyone with the account can read it;
//!   * NEVER rides on an argv (visible in the process list) — repo creation puts it in a curl `-K` config file
//!     (the exact trick llm.zig uses for the model key), the call's own and deleted once curl has exited;
//!   * NEVER lands in `.git/config`'s remote URL or the transcript — push authenticates through a one-shot
//!     `credential.helper store --file='<absolute path>'` credentials file (credentialHelperArg), the call's own and
//!     deleted once git has exited, while the persisted remote stays tokenless (`https://github.com/<owner>/<repo>.git`).
//! Those two call files sit in the sidecar dir, inside the data dir, which is often a synced folder. A desk that dies
//! mid-call never deletes its file, so the chat thread sweeps the stranded ones (sweepTokenFiles).
//!
//! Everything runs in the conversation's own `_chat/builds/{conv}/work` dir (a repo per conversation), via
//! `git -C <workdir>` so no process-wide cwd is touched. The Veil drives it through first-class tools
//! (repo_create / git_commit / git_push / git_status / git_log) rather than raw `RUN: git`, so the multi-step
//! flow — create the remote BEFORE pushing — is encoded once instead of fumbled by a weak model each time.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = @import("log.zig");
const nap = @import("nap.zig");

/// One git/GitHub operation's result, folded back into the chat like any tool result. `msg` is gpa-owned.
pub const Res = struct {
    ok: bool,
    msg: []u8,
    pub fn deinit(self: Res, gpa: std.mem.Allocator) void {
        gpa.free(self.msg);
    }
};

fn res(gpa: std.mem.Allocator, ok: bool, comptime fmt: []const u8, args: anytype) Res {
    return .{ .ok = ok, .msg = std.fmt.allocPrint(gpa, fmt, args) catch @constCast(if (ok) "ok" else "error") };
}

/// Where the git tools reach GitHub, and the programs that reach it.
const Endpoints = struct {
    /// repo_create's REST root: it posts to `{api}/user/repos`.
    api: []const u8,
    /// git_push's remote is `{web_scheme}://{web_host}/{owner}/{repo}.git`, and its credentials entry names the same
    /// scheme and host.
    web_scheme: []const u8,
    web_host: []const u8,
    curl: []const u8 = "curl",
    git: []const u8 = "git",
};

const GITHUB: Endpoints = .{ .api = "https://api.github.com", .web_scheme = "https", .web_host = "github.com" };

/// TEST ONLY: a `zig build test` build reads `test_endpoints` instead of GITHUB, so a test can aim the calls at a
/// stand-in on 127.0.0.1 or name a program no PATH holds. Until a test sets it, it names a closed loopback port, so a
/// test build never sends a token to the internet. A shipped build always uses GITHUB.
const TEST_NOWHERE: Endpoints = .{ .api = "http://127.0.0.1:9", .web_scheme = "http", .web_host = "127.0.0.1:9" };
var test_endpoints: Endpoints = TEST_NOWHERE;

fn endpoints() Endpoints {
    return if (builtin.is_test) test_endpoints else GITHUB;
}

/// True if `workdir` is already a git repo (has a .git entry).
fn isRepo(io: Io, gpa: std.mem.Allocator, workdir: []const u8) bool {
    const p = std.fmt.allocPrint(gpa, "{s}/.git", .{workdir}) catch return false;
    defer gpa.free(p);
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

/// Run `git -C workdir <args...>` and capture combined output (bounded). No process-wide cwd is changed.
fn git(gpa: std.mem.Allocator, io: Io, workdir: []const u8, args: []const []const u8) struct { ok: bool, out: []u8 } {
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ endpoints().git, "-C", workdir }) catch return .{ .ok = false, .out = gpa.dupe(u8, "oom") catch @constCast("oom") };
    av.appendSlice(gpa, args) catch return .{ .ok = false, .out = gpa.dupe(u8, "oom") catch @constCast("oom") };
    const r = std.process.run(gpa, io, .{
        .argv = av.items,
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(16 << 10),
    }) catch |e| return .{ .ok = false, .out = std.fmt.allocPrint(gpa, "git failed to run ({s}) — is git installed and on PATH?", .{@errorName(e)}) catch @constCast("git not found") };
    defer gpa.free(r.stderr);
    const ok = r.term == .exited and r.term.exited == 0;
    // git writes most human output to stderr; hand back whichever is substantial (stdout preferred when both).
    const out = std.mem.trim(u8, r.stdout, " \r\n\t");
    const err = std.mem.trim(u8, r.stderr, " \r\n\t");
    const body = if (out.len > 0) out else err;
    const dup = gpa.dupe(u8, body[0..@min(body.len, 4000)]) catch @constCast("");
    gpa.free(r.stdout);
    return .{ .ok = ok, .out = dup };
}

/// Ensure `workdir` is its OWN git repo (isolated), so neither the git tools NOR the model's `RUN: git` shell
/// can walk UP to a parent repo and commit into it — with the data dir inside nl-veil's own source tree, a
/// shell `git add -f` was observed force-committing a workdir file past .gitignore into the source repo. An
/// isolated `<workdir>/.git` makes git stop there. Idempotent, best-effort: a failure leaves prior behavior.
pub fn ensureRepo(gpa: std.mem.Allocator, io: Io, workdir: []const u8) void {
    if (isRepo(io, gpa, workdir)) return;
    const gi = git(gpa, io, workdir, &.{ "init", "-q", "-b", "main" });
    gpa.free(gi.out);
}

/// `git status --short --branch` — what changed + the current branch, compactly.
pub fn status(gpa: std.mem.Allocator, io: Io, workdir: []const u8) Res {
    if (!isRepo(io, gpa, workdir)) return res(gpa, true, "no repository here yet — git_commit will `git init` this workdir on first use.", .{});
    const g = git(gpa, io, workdir, &.{ "status", "--short", "--branch" });
    defer gpa.free(g.out);
    if (g.out.len == 0) return res(gpa, true, "clean working tree (nothing to commit).", .{});
    return res(gpa, g.ok, "{s}", .{g.out});
}

/// `git log --oneline -n N` — recent history.
pub fn logLine(gpa: std.mem.Allocator, io: Io, workdir: []const u8, n: u32) Res {
    if (!isRepo(io, gpa, workdir)) return res(gpa, true, "no repository / no commits yet.", .{});
    var nb: [8]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "-{d}", .{@min(n, 50)}) catch "-20";
    const g = git(gpa, io, workdir, &.{ "log", "--oneline", ns });
    defer gpa.free(g.out);
    if (!g.ok or g.out.len == 0) return res(gpa, true, "no commits yet.", .{});
    return res(gpa, true, "{s}", .{g.out});
}

/// Stage everything and commit. Auto-`git init` on first use. Author name/email are set PER-COMMIT with `-c`
/// (never touching the machine's global git config). Returns the new commit's short summary.
pub fn commit(gpa: std.mem.Allocator, io: Io, workdir: []const u8, author_name: []const u8, author_email: []const u8, message: []const u8) Res {
    if (std.mem.trim(u8, message, " \r\n\t").len == 0) return res(gpa, false, "a commit needs a message.", .{});
    if (!isRepo(io, gpa, workdir)) {
        const gi = git(gpa, io, workdir, &.{ "init", "-q", "-b", "main" });
        gpa.free(gi.out);
    }
    const ga = git(gpa, io, workdir, &.{ "add", "-A" });
    gpa.free(ga.out);
    const nm = if (author_name.len > 0) author_name else "nl-veil";
    const em = if (author_email.len > 0) author_email else "veil@nl-veil.local";
    var cn: [160]u8 = undefined;
    var ce: [200]u8 = undefined;
    const c_name = std.fmt.bufPrint(&cn, "user.name={s}", .{nm}) catch "user.name=nl-veil";
    const c_email = std.fmt.bufPrint(&ce, "user.email={s}", .{em}) catch "user.email=veil@nl-veil.local";
    const g = git(gpa, io, workdir, &.{ "-c", c_name, "-c", c_email, "commit", "-q", "-m", message });
    defer gpa.free(g.out);
    if (!g.ok) {
        if (std.mem.indexOf(u8, g.out, "nothing to commit") != null)
            return res(gpa, true, "nothing to commit — the working tree already matches the last commit.", .{});
        return res(gpa, false, "commit failed: {s}", .{g.out});
    }
    // report the new HEAD so the veil sees the commit landed
    const h = git(gpa, io, workdir, &.{ "log", "--oneline", "-1" });
    defer gpa.free(h.out);
    return res(gpa, true, "committed: {s}", .{h.out});
}

pub const RepoInfo = struct { ok: bool, clone_url: []const u8, html_url: []const u8, full_name: []const u8, err: []const u8 };

/// Parse the GitHub `POST /user/repos` response. On success it carries clone_url/html_url/full_name; on failure
/// a top-level {"message": "..."}. Pure — slices into `body`, unit-tested.
pub fn parseRepoCreate(body: []const u8) RepoInfo {
    const clone = jsonStr(body, "clone_url");
    const html = jsonStr(body, "html_url");
    const full = jsonStr(body, "full_name");
    if (clone.len > 0) return .{ .ok = true, .clone_url = clone, .html_url = html, .full_name = full, .err = "" };
    return .{ .ok = false, .clone_url = "", .html_url = "", .full_name = "", .err = jsonStr(body, "message") };
}

/// A repo name GitHub will accept: keep [A-Za-z0-9._-], turn spaces/other into '-', collapse repeats, bound
/// length. Pure — unit-tested. Empty → "" (caller rejects).
pub fn sanitizeRepoName(in: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var last_dash = false;
    for (in) |c| {
        if (w >= out.len or w >= 90) break;
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (ok) {
            out[w] = c;
            w += 1;
            last_dash = false;
        } else if (!last_dash and w > 0) {
            out[w] = '-';
            w += 1;
            last_dash = true;
        }
    }
    return std.mem.trim(u8, out[0..w], "-._");
}

// ---- the token's files ----
//
// repo_create and git_push hand the PAT to their child through a file, because an argv shows in the process list.
// Both files sit in the sidecar dir the chat thread passes ({data}/.veil-desk), inside the data dir, which is often a
// synced folder. A call deletes its own file once its child has exited, and the chat thread sweeps the ones a desk that
// died mid-call left behind (sweepTokenFiles).

/// repo_create's curl config: `header = "Authorization: token <PAT>"`. Builds before 2026-09-17 wrote exactly this
/// name, one per sidecar, and a desk that died mid-call left it there.
const CURL_CFG = ".ghcurlcfg";
/// git_push's credentials file: `https://<user>:<PAT>@github.com`. Builds before 2026-09-17 wrote exactly this name,
/// one per sidecar, and a desk that died mid-push left it there.
const GIT_CRED = ".gitcred";
/// git's credential store rewrites its file by writing all of it, token included, to `<file>.lock` and renaming that
/// over the file: it does so once a push authenticates, re-creating a file that was already gone. A git killed in
/// between leaves the lock.
const LOCK_SUFFIX = ".lock";

/// Room for a token file's path. A call refuses a sidecar dir too long for it rather than write a token it could not
/// later delete by name.
const TOKEN_PATH_CAP = 640;

/// A call's own token file, `{dir}/{kind}-{16 hex}`, formatted into `buf`; null when it does not fit.
///
/// PER CALL, NOT PER DIR. Two desks on one data dir share the sidecar, and a call deletes its file once its child has
/// exited. Under one fixed name, one desk's call ending could delete the file another desk's call had just written,
/// before that call's curl or git read it. So a call only ever deletes its own file, and the sweep only files no live
/// call can still need.
fn tokenPath(io: Io, dir: []const u8, comptime kind: []const u8, buf: []u8) ?[]const u8 {
    var sfx: [8]u8 = undefined;
    io.random(&sfx);
    const hex = std.fmt.bytesToHex(sfx, .lower);
    return std.fmt.bufPrint(buf, "{s}/" ++ kind ++ "-{s}", .{ dir, &hex }) catch null;
}

/// Whether a file `name` is a token file a git tool wrote: a call's own (tokenPath), the fixed name earlier builds
/// used, or a credentials file's lock. Nothing else in the sidecar is this module's to delete: not the stored token
/// (secrets.zig), and not the model calls' curl configs (llm.isKeyCfgName), which have their own sweep and age floor.
pub fn isTokenFileName(name: []const u8) bool {
    if (isOwnName(name, CURL_CFG)) return true;
    const stem = if (std.mem.endsWith(u8, name, LOCK_SUFFIX)) name[0 .. name.len - LOCK_SUFFIX.len] else name;
    return isOwnName(stem, GIT_CRED);
}

/// `kind` itself, or `kind` + `-` + the 16 lowercase hex tokenPath writes.
fn isOwnName(name: []const u8, comptime kind: []const u8) bool {
    if (!std.mem.startsWith(u8, name, kind)) return false;
    const sfx = name[kind.len..];
    if (sfx.len == 0) return true;
    if (sfx.len != 17 or sfx[0] != '-') return false;
    for (sfx[1..]) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

/// How long repo_create's curl may run (its --max-time). curl reads its config once, at startup.
const REPO_CREATE_MAX_TIME_S = 25;

/// How often a push re-stamps its credentials file while git runs (Lease).
const LEASE_BEAT_S = 60;

/// How long after its last write a token file counts as stranded (sweepTokenFiles). A repo_create config is gone once
/// its curl exits, within REPO_CREATE_MAX_TIME_S. A push has no timeout, so no age floor could outlast one; instead its
/// Lease re-stamps the file every LEASE_BEAT_S for as long as git runs, and the floor is twenty beats, so a run of
/// re-stamps that failed while something held the file open still never makes a live push's file look stranded. An
/// older file was left by a desk that died mid-call, or by a build before 2026-09-17. A younger one may belong to a
/// live call on another desk sharing this data dir, and a sweep must never take that one.
pub const TOKEN_FILE_STALE_S: i64 = 20 * 60;

/// Remove the stranded token files at the top level of `dir_path`: files isTokenFileName names that were last written
/// more than TOKEN_FILE_STALE_S before `now_ns`. Nothing below the top level is read. Returns how many it removed.
pub fn sweepTokenFiles(io: Io, gpa: std.mem.Allocator, dir_path: []const u8, now_ns: i96) usize {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    // Names first, THEN deletes: a dir changed mid-iteration can skip an entry.
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        // Anything but a dir. Zig lists every Windows reparse point as a symlink, and a synced folder's placeholder
        // file can be one.
        if (ent.kind == .directory or !isTokenFileName(ent.name)) continue;
        const dup = gpa.dupe(u8, ent.name) catch continue;
        names.append(gpa, dup) catch {
            gpa.free(dup);
            continue;
        };
    }
    const stale_ns = @as(i96, TOKEN_FILE_STALE_S) * std.time.ns_per_s;
    var removed: usize = 0;
    for (names.items) |n| {
        const st = dir.statFile(io, n, .{ .follow_symlinks = false }) catch continue;
        if (now_ns - st.mtime.nanoseconds <= stale_ns) continue;
        dir.deleteFile(io, n) catch continue;
        removed += 1;
    }
    return removed;
}

/// Delete a call's token file once its child has exited. One that will not go (held open by a scanner or a sync
/// client) is logged, and the chat thread's sweep takes it once it is stale.
fn dropTokenFile(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => log.warn("git tools: could not delete token file {s}: {t}", .{ path, e }),
    };
}

/// The beat a Lease keeps. TEST ONLY: a `zig build test` build beats every `test_lease_beat_ms` instead, so a test sees
/// a re-stamp without waiting a minute. A shipped build always beats every LEASE_BEAT_S.
var test_lease_beat_ms: u64 = LEASE_BEAT_S * std.time.ms_per_s;

/// Keeps a push's credentials file young while git runs, so no sweep takes it mid-push. This desk's own sweep runs on
/// the chat thread, which is busy with the push, but another desk on the same data dir sweeps on its own schedule, and
/// a push has no timeout: a stalled network can hold git before it reads the file for longer than any age floor. A
/// thread of the lease's own re-stamps the file's mtime every beat until the push returns. If the desk dies, the
/// stamps stop and the file ages out.
const Lease = struct {
    io: Io,
    path: []const u8,
    over: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Starts in place: the thread holds a pointer to the struct, which must stay put until `end`.
    fn begin(l: *Lease) void {
        l.thread = std.Thread.spawn(.{}, keep, .{l}) catch |e| blk: {
            log.warn("git push: no lease on {s} ({t}); a push running past {d}s can lose it to another desk's sweep", .{ l.path, e, TOKEN_FILE_STALE_S });
            break :blk null;
        };
    }

    fn end(l: *Lease) void {
        l.over.store(true, .release);
        if (l.thread) |t| t.join();
        l.thread = null;
    }

    fn keep(l: *Lease) void {
        const beat_ms: u64 = if (builtin.is_test) test_lease_beat_ms else LEASE_BEAT_S * std.time.ms_per_s;
        const step_ms: u64 = @min(beat_ms, 100); // how soon `end` is noticed
        var waited_ms: u64 = 0;
        while (!l.over.load(.acquire)) {
            nap.ms(step_ms); // a plain thread never sleeps on the Io runtime (nap.zig)
            waited_ms += step_ms;
            if (waited_ms < beat_ms) continue;
            waited_ms = 0;
            restamp(l.io, l.path);
        }
    }
};

/// Set a file's mtime to now, if the file is still there. Never creates it.
fn restamp(io: Io, path: []const u8) void {
    const f = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return;
    defer f.close(io);
    f.setTimestampsNow(io) catch {};
}

/// Create a GitHub repo via the REST API using the PAT. The token rides in a curl `-K` CONFIG FILE (auth header),
/// NEVER on the argv: the call's own (tokenPath), written under `sidecar_dir` right before curl starts and deleted
/// once curl has exited. Returns the parsed repo info (clone/html url) or an error message. `name` is used verbatim
/// (caller sanitizes).
pub fn repoCreate(gpa: std.mem.Allocator, io: Io, sidecar_dir: []const u8, pat: []const u8, name: []const u8, private: bool) Res {
    // The claim in this message is the one thing here a user cannot check for themselves, so it says
    // what secrets.zig actually does: a plaintext file under the local data dir. What IS guaranteed —
    // never on an argv, never in the transcript, never over the wire — is stated instead, because
    // those are the properties gitvc genuinely enforces.
    if (pat.len == 0) return res(gpa, false, "no GitHub token configured — set one with `::pat <token>` (or the Settings pane) first. It is kept in a local file readable by your account, never written to the transcript and never sent over the wire.", .{});
    if (name.len == 0) return res(gpa, false, "a repository name is required.", .{});
    const gh = endpoints();
    var cfg_buf: [TOKEN_PATH_CAP]u8 = undefined;
    const cfg_path = tokenPath(io, sidecar_dir, CURL_CFG, &cfg_buf) orelse return res(gpa, false, "path too long", .{});
    // curl config: the auth header (with the PAT) lives here, off the argv.
    const cfg = std.fmt.allocPrint(gpa, "header = \"Authorization: token {s}\"\nheader = \"Accept: application/vnd.github+json\"\nheader = \"User-Agent: nl-veil\"\n", .{pat}) catch return res(gpa, false, "oom", .{});
    defer gpa.free(cfg);
    const payload = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"private\":{s},\"auto_init\":false}}", .{ name, if (private) "true" else "false" }) catch return res(gpa, false, "oom", .{});
    defer gpa.free(payload);
    const url = std.fmt.allocPrint(gpa, "{s}/user/repos", .{gh.api}) catch return res(gpa, false, "oom", .{});
    defer gpa.free(url);
    // THE TOKEN LEAVES WITH THE CALL. The delete is armed before the write, so a write that fails halfway or a curl that
    // never launches leaves nothing, and std.process.run returns only once curl is gone.
    defer dropTokenFile(io, cfg_path);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = cfg }) catch return res(gpa, false, "could not stage the request", .{});
    const argv = [_][]const u8{ gh.curl, "-sS", "--max-time", std.fmt.comptimePrint("{d}", .{REPO_CREATE_MAX_TIME_S}), "-K", cfg_path, "-X", "POST", url, "-d", payload };
    const r = std.process.run(gpa, io, .{ .argv = &argv, .stdout_limit = .limited(64 << 10), .stderr_limit = .limited(8 << 10) }) catch return res(gpa, false, "curl failed to run — is curl installed?", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const info = parseRepoCreate(r.stdout);
    if (info.ok) return res(gpa, true, "created {s} — {s}\n(remote will be set on the next git_push)", .{ info.full_name, info.html_url });
    const why = if (info.err.len > 0) info.err else std.mem.trim(u8, r.stderr, " \r\n\t");
    return res(gpa, false, "GitHub rejected the repo create: {s}", .{if (why.len > 0) why else "unknown error (check the token's `repo` scope)"});
}

/// Room for push's `-c credential.helper=...` argument: the fixed text, around a credentials file's path in which
/// every byte could be a quote, written as four.
const HELPER_ARG_CAP = "credential.helper=store --file=''".len + 4 * TOKEN_PATH_CAP;

/// The `-c` argument that makes the credentials file at `path` push's only credential helper,
/// `credential.helper=store --file='<path>'`, formatted into `buf`; null when it does not fit.
///
/// git runs a helper whose name does not begin with `!` as the command `git credential-store --file=<path> get`, through
/// its shell (sh), in the `git -C` workdir. So `path` has to come through sh intact and name the file from the workdir.
/// Builds before 2026-09-17 passed the sidecar path as the desk holds it, and neither a Windows desk nor a standalone
/// one could authenticate a push (measured against a 127.0.0.1 stand-in that asks for credentials, with Git for Windows
/// 2.52 and with git 2.43 under dash):
/// - `path` is absolute: push resolves the sidecar before it names the file. The standalone desk's data dir is
///   cwd-relative ("data"), and a relative path named a file inside the workdir, where there is none.
/// - It is single-quoted, and an embedded `'` is written `'\''`. Unquoted, sh took each backslash in the in-process
///   GUI's `{exe home}/data` for an escape ("fatal: unable to open C:Usersgarys..."), and a space, as in a
///   "OneDrive - <org>" folder, split the word ("usage: git credential-store").
/// - On Windows a backslash is written as a forward slash, which Windows reads the same way. Git for Windows 2.52 needs
///   only the quotes: a single-quoted backslash path, UNC ones included, reached credential-store intact, so no test
///   here can tell the two apart. The slash keeps the path from depending on how a shell hop treats a backslash.
fn credentialHelperArg(buf: []u8, path: []const u8) ?[]const u8 {
    var w: Io.Writer = .fixed(buf);
    w.writeAll("credential.helper=store --file='") catch return null;
    for (path) |c| switch (c) {
        '\'' => w.writeAll("'\\''") catch return null, // close the quote, a quoted quote, reopen
        '\\' => w.writeByte(if (builtin.os.tag == .windows) '/' else '\\') catch return null,
        else => w.writeByte(c) catch return null,
    };
    w.writeByte('\'') catch return null;
    return w.buffered();
}

/// Push the conversation's repo to `owner/repo`. The remote is (re)set TOKENLESS
/// (`https://github.com/<owner>/<repo>.git`); the PAT is supplied through a one-shot git credentials file
/// (`credential.helper=store --file='<path>'`, credentialHelperArg): the call's own (tokenPath), written under the
/// absolute path of `sidecar_dir` right before git starts, kept young by a Lease while git runs, and deleted once git
/// has exited — so the token never touches the argv, `.git/config`, or the transcript. Auto-commits nothing; caller
/// commits first.
pub fn push(gpa: std.mem.Allocator, io: Io, workdir: []const u8, sidecar_dir: []const u8, owner: []const u8, repo: []const u8, user: []const u8, pat: []const u8, branch: []const u8) Res {
    if (!isRepo(io, gpa, workdir)) return res(gpa, false, "nothing to push — commit something first (git_commit).", .{});
    if (pat.len == 0) return res(gpa, false, "no GitHub token configured — set one with `::pat <token>` first.", .{});
    if (owner.len == 0 or repo.len == 0) return res(gpa, false, "no remote yet — run repo_create (or tell me the owner/repo) before pushing.", .{});
    const br = if (branch.len > 0) branch else "main";
    const gh = endpoints();
    // remote 'origin' = tokenless https url (idempotent: set-url, else add)
    const remote_url = std.fmt.allocPrint(gpa, "{s}://{s}/{s}/{s}.git", .{ gh.web_scheme, gh.web_host, owner, repo }) catch return res(gpa, false, "oom", .{});
    defer gpa.free(remote_url);
    const su = git(gpa, io, workdir, &.{ "remote", "set-url", "origin", remote_url });
    gpa.free(su.out);
    if (!su.ok) {
        const ad = git(gpa, io, workdir, &.{ "remote", "add", "origin", remote_url });
        gpa.free(ad.out);
    }
    // the call's own credentials file, named by the sidecar's absolute path: git reads it from the workdir, through its
    // shell (credentialHelperArg). `credential.useHttpPath=false` so one entry covers the repo.
    var side_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const side_len = Io.Dir.cwd().realPathFile(io, sidecar_dir, &side_buf) catch |e| return res(gpa, false, "could not stage credentials: no absolute path for {s} ({t})", .{ sidecar_dir, e });
    var cred_buf: [TOKEN_PATH_CAP]u8 = undefined;
    const cred_path = tokenPath(io, side_buf[0..side_len], GIT_CRED, &cred_buf) orelse return res(gpa, false, "path too long", .{});
    const un = if (user.len > 0) user else owner;
    const cred = std.fmt.allocPrint(gpa, "{s}://{s}:{s}@{s}\n", .{ gh.web_scheme, un, pat, gh.web_host }) catch return res(gpa, false, "oom", .{});
    defer gpa.free(cred);
    var helper_buf: [HELPER_ARG_CAP]u8 = undefined;
    const helper = credentialHelperArg(&helper_buf, cred_path) orelse return res(gpa, false, "path too long", .{});
    // THE TOKEN LEAVES WITH THE CALL. The delete is armed before the write, so a write that fails halfway or a git that
    // never launches leaves nothing, and std.process.run returns only once git is gone.
    defer dropTokenFile(io, cred_path);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = cred_path, .data = cred }) catch return res(gpa, false, "could not stage credentials", .{});
    const g = pushed: {
        var lease: Lease = .{ .io = io, .path = cred_path };
        lease.begin();
        defer lease.end(); // the lease's thread is joined before the file is deleted
        break :pushed git(gpa, io, workdir, &.{ "-c", "credential.useHttpPath=false", "-c", "credential.helper=", "-c", helper, "push", "-u", "origin", br });
    };
    defer gpa.free(g.out);
    if (!g.ok) return res(gpa, false, "push failed: {s}", .{scrub(g.out, pat)});
    return res(gpa, true, "pushed {s} to github.com/{s}/{s}", .{ br, owner, repo });
}

/// Belt-and-suspenders: never let the PAT survive into a returned message even if git echoed a credentialed URL.
fn scrub(s: []const u8, pat: []const u8) []const u8 {
    if (pat.len >= 6 and std.mem.indexOf(u8, s, pat) != null) return "(auth error — token redacted; check the token's scope/expiry)";
    return s;
}

/// Minimal string-field extractor: the value of "key":"..." (first match), unescaping nothing (GitHub urls have
/// no escapes). Returns a slice into `body`. Good enough for the flat fields we read.
fn jsonStr(body: []const u8, key: []const u8) []const u8 {
    var kb: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&kb, "\"{s}\"", .{key}) catch return "";
    const at = std.mem.indexOf(u8, body, needle) orelse return "";
    var i = at + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':' or body[i] == '\t')) i += 1;
    if (i >= body.len or body[i] != '"') return "";
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\') i += 1; // skip an escape pair
    }
    return body[start..@min(i, body.len)];
}

// ------------------------------------------------------------------------------------------------ tests

test "sanitizeRepoName keeps a valid name, converts spaces/junk to single dashes, trims edges" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("neuronet", sanitizeRepoName("neuronet", &buf));
    try std.testing.expectEqualStrings("my-cool-repo", sanitizeRepoName("my cool repo", &buf));
    try std.testing.expectEqualStrings("a-b-c", sanitizeRepoName("a  b//c", &buf));
    try std.testing.expectEqualStrings("keep.dots_and-dashes", sanitizeRepoName("keep.dots_and-dashes", &buf));
    try std.testing.expectEqualStrings("edges", sanitizeRepoName("--edges--", &buf));
    try std.testing.expectEqualStrings("", sanitizeRepoName("///", &buf));
}

test "parseRepoCreate: success carries urls; failure carries the message" {
    const ok = parseRepoCreate("{\"full_name\":\"me/x\",\"html_url\":\"https://github.com/me/x\",\"clone_url\":\"https://github.com/me/x.git\"}");
    try std.testing.expect(ok.ok);
    try std.testing.expectEqualStrings("https://github.com/me/x.git", ok.clone_url);
    try std.testing.expectEqualStrings("me/x", ok.full_name);
    const bad = parseRepoCreate("{\"message\":\"Repository creation failed. name already exists\",\"status\":\"422\"}");
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("Repository creation failed. name already exists", bad.err);
}

test "scrub never lets the PAT survive into a returned error" {
    const pat = "ghp_SECRETSECRETSECRET";
    const leaked = "fatal: could not read from https://user:ghp_SECRETSECRETSECRET@github.com/...";
    try std.testing.expect(std.mem.indexOf(u8, scrub(leaked, pat), pat) == null);
    // an unrelated error passes through unchanged
    try std.testing.expectEqualStrings("fatal: repository not found", scrub("fatal: repository not found", pat));
}

test "jsonStr extracts flat string fields and stops at the closing quote" {
    const b = "{\"a\":\"one\",\"clone_url\":\"https://x.git\",\"n\":5}";
    try std.testing.expectEqualStrings("one", jsonStr(b, "a"));
    try std.testing.expectEqualStrings("https://x.git", jsonStr(b, "clone_url"));
    try std.testing.expectEqualStrings("", jsonStr(b, "missing"));
}

// ---- a call's token leaves with it ----
//
// A git tool's call file is the one place it puts the PAT on disk, in the sidecar, inside a data dir that is often
// synced. Builds before 2026-09-17 deleted it only when the call returned, under one fixed name, so a desk that died
// mid-call left it for good. These tests run the REAL curl and git against a stand-in listening on 127.0.0.1 only, then
// read back every file each call left in a real temp dir.

/// Never a real credential; distinctive, so a byte search for it is exact.
const TEST_PAT = "ghp_gitvc-token-scratch-test-not-a-real-credential";
const TEST_CREATED_BODY = "{\"full_name\":\"me/scratch\",\"html_url\":\"https://github.com/me/scratch\",\"clone_url\":\"https://github.com/me/scratch.git\"}";
/// GitHub made the repo.
const TEST_CREATED = std.fmt.comptimePrint("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ TEST_CREATED_BODY.len, TEST_CREATED_BODY });
const TEST_REJECTED_BODY = "{\"message\":\"Repository creation failed.\"}";
/// GitHub refused to make it.
const TEST_REJECTED = std.fmt.comptimePrint("HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ TEST_REJECTED_BODY.len, TEST_REJECTED_BODY });
/// The remote refuses a push outright, before git asks for credentials.
const TEST_FORBIDDEN = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
/// The remote wants credentials first, as GitHub does before it takes a push: git asks its credential helper, then asks
/// the remote again with what the helper gave.
const TEST_CHALLENGE = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"GitHub\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
/// The Authorization header git sends once it has read a test push's credentials file: user `gitvc-test` and the token.
const TEST_BASIC_AUTH = basic: {
    const pair = "gitvc-test:" ++ TEST_PAT;
    var b64: [std.base64.standard.Encoder.calcSize(pair.len)]u8 = undefined;
    break :basic "Basic " ++ std.base64.standard.Encoder.encode(&b64, pair);
};

/// TEST ONLY. GitHub's API and git host on 127.0.0.1, at a port the OS assigns (a fixed port is shared rather than
/// exclusive on Windows, and a wildcard listen raises a Windows Firewall prompt). It reads each request whole and keeps
/// the first, runs `hook` while the client waits for its answer, then answers `reply` and closes. An empty `reply`
/// closes with nothing said: a dead transfer.
const Standin = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    reply: []const u8,
    hook: ?Hook,
    /// A request that carries no Authorization header is answered TEST_CHALLENGE instead of `reply`.
    challenge: bool,
    closing: std.atomic.Value(bool),
    /// Requests read whole so far. The first is in `req` once this is 1, and nothing writes `req` after that.
    seen: std.atomic.Value(u32),
    req: [16 << 10]u8,
    req_len: usize,
    /// The value of the first Authorization header a request carried. Complete once `stop` has returned.
    auth: [512]u8,
    auth_len: usize,
    api: [40]u8,
    api_len: usize,
    host: [24]u8,
    host_len: usize,
    thread: std.Thread,

    const Hook = struct { ctx: *anyopaque, run: *const fn (ctx: *anyopaque) void };

    /// Starts in place: the serve thread holds a pointer to the struct, so it must not be copied.
    fn start(sv: *Standin, io: Io, reply: []const u8, hook: ?Hook) !void {
        return sv.open(io, reply, hook, false);
    }

    /// `start`, as a remote that wants credentials: a request without them is answered TEST_CHALLENGE, and one with them
    /// `reply`.
    fn startChallenging(sv: *Standin, io: Io, reply: []const u8) !void {
        return sv.open(io, reply, null, true);
    }

    fn open(sv: *Standin, io: Io, reply: []const u8, hook: ?Hook, challenge: bool) !void {
        const addr = Io.net.IpAddress{ .ip4 = .loopback(0) };
        sv.server = Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch return error.SkipZigTest; // no loopback listener on this box
        sv.io = io;
        sv.port = sv.server.socket.address.getPort();
        sv.reply = reply;
        sv.hook = hook;
        sv.challenge = challenge;
        sv.closing = .init(false);
        sv.seen = .init(0);
        sv.req_len = 0;
        sv.auth_len = 0;
        sv.api_len = (std.fmt.bufPrint(&sv.api, "http://127.0.0.1:{d}", .{sv.port}) catch unreachable).len;
        sv.host_len = (std.fmt.bufPrint(&sv.host, "127.0.0.1:{d}", .{sv.port}) catch unreachable).len;
        sv.thread = std.Thread.spawn(.{}, serve, .{sv}) catch |e| {
            sv.server.deinit(io);
            return e;
        };
    }

    /// Every git tool's endpoints, aimed here.
    fn aimed(sv: *const Standin) Endpoints {
        return .{ .api = sv.api[0..sv.api_len], .web_scheme = "http", .web_host = sv.host[0..sv.host_len] };
    }

    fn serve(sv: *Standin) void {
        while (true) {
            const conn = sv.server.accept(sv.io) catch return;
            defer conn.close(sv.io);
            if (sv.closing.load(.acquire)) return; // stop()'s wake-up dial
            const first = sv.seen.load(.acquire) == 0;
            var rbuf: [4 << 10]u8 = undefined;
            var rd = conn.reader(sv.io, &rbuf);
            var clen: usize = 0;
            var authorized = false;
            while (true) {
                const line = (rd.interface.takeDelimiter('\n') catch break) orelse break;
                if (first) {
                    sv.keep(line);
                    sv.keep("\n");
                }
                if (contentLength(line)) |n| clen = n;
                if (headerValue(line, "authorization:")) |v| {
                    authorized = true;
                    sv.keepAuth(v);
                }
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }
            if (clen > 0) {
                var body: [8 << 10]u8 = undefined;
                const n = @min(clen, body.len);
                if (rd.interface.readSliceAll(body[0..n])) {
                    if (first) sv.keep(body[0..n]);
                } else |_| {}
            }
            _ = sv.seen.fetchAdd(1, .release);
            if (sv.hook) |h| h.run(h.ctx);
            var wbuf: [8 << 10]u8 = undefined;
            var wr = conn.writer(sv.io, &wbuf);
            wr.interface.writeAll(if (sv.challenge and !authorized) TEST_CHALLENGE else sv.reply) catch {};
            wr.interface.flush() catch {};
        }
    }

    fn keep(sv: *Standin, bytes: []const u8) void {
        const n = @min(bytes.len, sv.req.len - sv.req_len);
        @memcpy(sv.req[sv.req_len..][0..n], bytes[0..n]);
        sv.req_len += n;
    }

    fn keepAuth(sv: *Standin, value: []const u8) void {
        if (sv.auth_len > 0) return;
        const n = @min(value.len, sv.auth.len);
        @memcpy(sv.auth[0..n], value[0..n]);
        sv.auth_len = n;
    }

    /// The first request, head and body. Complete once `seen` is 1.
    fn request(sv: *const Standin) []const u8 {
        return sv.req[0..sv.req_len];
    }

    /// The first Authorization header's value, "" when no request carried one. Read it after `stop`.
    fn authorization(sv: *const Standin) []const u8 {
        return sv.auth[0..sv.auth_len];
    }

    /// Dials its own port once, so a serve loop parked in accept wakes and exits.
    fn stop(sv: *Standin) void {
        sv.closing.store(true, .release);
        const addr = Io.net.IpAddress{ .ip4 = .loopback(sv.port) };
        if (Io.net.IpAddress.connect(&addr, sv.io, .{ .mode = .stream })) |c| c.close(sv.io) else |_| {}
        sv.thread.join();
        sv.server.deinit(sv.io);
    }

    /// `Content-Length: N` -> N, in any letter case. Anything else -> null.
    fn contentLength(line: []const u8) ?usize {
        return std.fmt.parseInt(usize, headerValue(line, "content-length:") orelse return null, 10) catch null;
    }

    /// The value on a header `line` named `name` (lowercase, with its colon), in any letter case. Another line -> null.
    fn headerValue(line: []const u8, comptime name: []const u8) ?[]const u8 {
        if (line.len < name.len) return null;
        for (line[0..name.len], name) |a, b| if (std.ascii.toLower(a) != b) return null;
        return std.mem.trim(u8, line[name.len..], " \t\r");
    }
};

/// An Io that can spawn curl and git: with Threaded's empty default environment a child cannot even init Winsock on
/// Windows (llm.osEnviron).
fn testThreaded(gpa: std.mem.Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(gpa, .{ .environ = @import("llm.zig").osEnviron() });
}

/// `{root}/work`, a repo with one commit to push, and `{root}/side`, an empty sidecar. Skips when git is missing.
fn testRepo(gpa: std.mem.Allocator, io: Io, root: []const u8, work: []const u8, side: []const u8) !void {
    Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = try Io.Dir.cwd().createDirPathStatus(io, work, .default_dir);
    _ = try Io.Dir.cwd().createDirPathStatus(io, side, .default_dir);
    ensureRepo(gpa, io, work);
    if (!isRepo(io, gpa, work)) return error.SkipZigTest; // no git on this box
    var pb: [256]u8 = undefined;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&pb, "{s}/README.md", .{work}), .data = "scratch\n" });
    const add = git(gpa, io, work, &.{ "add", "-A" });
    gpa.free(add.out);
    // unsigned, whatever the machine's global config asks for
    const made = git(gpa, io, work, &.{ "-c", "commit.gpgsign=false", "-c", "user.name=gitvc-test", "-c", "user.email=gitvc-test@localhost", "commit", "-q", "-m", "scratch" });
    defer gpa.free(made.out);
    if (!made.ok) {
        std.debug.print("\ncould not make the test repo's commit: {s}\n", .{made.out});
        return error.TestRepoCommitFailed;
    }
}

/// Fails if any file at the top of `dir_path`, but `except`, is a token file or holds `pat`. Returns how many files
/// it read.
fn expectNoTokenOnDisk(gpa: std.mem.Allocator, io: Io, dir_path: []const u8, pat: []const u8, except: []const u8) !usize {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var files: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .file) continue;
        files += 1;
        if (std.mem.eql(u8, ent.name, except)) continue;
        if (isTokenFileName(ent.name)) {
            std.debug.print("\na token file outlived its call: {s}/{s}\n", .{ dir_path, ent.name });
            return error.TokenFileLeft;
        }
        const data = try dir.readFileAlloc(io, ent.name, gpa, .limited(4 << 20));
        defer gpa.free(data);
        if (std.mem.indexOf(u8, data, pat) != null) {
            std.debug.print("\nthe token is still on disk: {s}/{s}\n", .{ dir_path, ent.name });
            return error.TokenOnDisk;
        }
    }
    return files;
}

/// Fails unless the file at `path` still holds exactly `want`: another call's token file, which no call of this
/// test's may touch.
fn expectUntouched(gpa: std.mem.Allocator, io: Io, path: []const u8, want: []const u8) !void {
    const got = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16)) catch |e| {
        std.debug.print("\na call removed another call's token file ({s}): {t}\n", .{ path, e });
        return error.SiblingTokenFileGone;
    };
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a repo_create call's token leaves with it: no curl config outlives a created repo, a rejection, a dead transfer or a curl that never launches" {
    const gpa = std.testing.allocator;
    var threaded = testThreaded(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const side = "zig-gitvc-repocreate-tmp";
    Io.Dir.cwd().deleteTree(io, side) catch {};
    defer Io.Dir.cwd().deleteTree(io, side) catch {};
    _ = try Io.Dir.cwd().createDirPathStatus(io, side, .default_dir);
    defer test_endpoints = TEST_NOWHERE;

    // Another desk on this data dir has a repo_create running: its config is written, and its curl may not have read
    // it yet.
    var sib_buf: [TOKEN_PATH_CAP]u8 = undefined;
    const sibling = tokenPath(io, side, CURL_CFG, &sib_buf).?;
    const sibling_cfg = "header = \"Authorization: token the-other-desk's-own-token\"\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sibling, .data = sibling_cfg });

    const End = enum { created, rejected, dead, no_curl };
    const Case = struct { end: End, reply: []const u8 = "", ok: bool = false, msg: []const u8 };
    const cases = [_]Case{
        .{ .end = .created, .reply = TEST_CREATED, .ok = true, .msg = "created me/scratch" },
        .{ .end = .rejected, .reply = TEST_REJECTED, .msg = "Repository creation failed." },
        // read, then closed with nothing said: curl exits 52
        .{ .end = .dead, .msg = "(52)" },
        // no curl on PATH: the config is written, and nothing ever reads it
        .{ .end = .no_curl, .msg = "curl failed to run" },
    };
    for (cases) |c| {
        var sv: Standin = undefined;
        try sv.start(io, c.reply, null);
        var sv_up = true;
        defer if (sv_up) sv.stop();
        test_endpoints = sv.aimed();
        if (c.end == .no_curl) test_endpoints.curl = "nl-veil-test-no-such-curl";
        const r = repoCreate(gpa, io, side, TEST_PAT, "scratch", true);
        defer r.deinit(gpa);
        sv.stop();
        sv_up = false;
        if (r.ok != c.ok or std.mem.indexOf(u8, r.msg, c.msg) == null) {
            std.debug.print("\n[{t}] expected ok={} naming \"{s}\", got ok={} \"{s}\"\n", .{ c.end, c.ok, c.msg, r.ok, r.msg });
            return error.WrongEnding;
        }
        if (c.end != .no_curl) {
            // curl READ the config before it went: the token reached the wire. A delete that ran before curl started
            // would pass the disk checks below and fail every real call.
            if (std.mem.indexOf(u8, sv.request(), "Authorization: token " ++ TEST_PAT) == null) {
                std.debug.print("\n[{t}] the stand-in never saw the token:\n{s}\n", .{ c.end, sv.request() });
                return error.TokenNeverSent;
            }
        }
        try expectUntouched(gpa, io, sibling, sibling_cfg);
        // The sibling's config is the one file left: the count is also the proof the scan looked where the call wrote.
        try std.testing.expectEqual(@as(usize, 1), try expectNoTokenOnDisk(gpa, io, side, TEST_PAT, std.fs.path.basename(sibling)));
    }
}

/// What a push's credentials file looked like when git's first request reached the stand-in.
const PushSeen = struct {
    io: Io,
    gpa: std.mem.Allocator,
    side: []const u8,
    sibling: []const u8,
    /// The push's own credentials file was on disk and held the token while git ran.
    held: bool = false,

    fn look(ctx: *anyopaque) void {
        const ps: *PushSeen = @ptrCast(@alignCast(ctx));
        var name_buf: [64]u8 = undefined;
        const name = ownCredFile(ps.io, ps.side, ps.sibling, &name_buf) orelse return;
        var pb: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ ps.side, name }) catch return;
        const data = Io.Dir.cwd().readFileAlloc(ps.io, path, ps.gpa, .limited(1 << 16)) catch return;
        defer ps.gpa.free(data);
        ps.held = std.mem.indexOf(u8, data, TEST_PAT) != null;
    }
};

/// The one credentials file in `side` other than `sibling`, named into `buf`: the running push's own.
fn ownCredFile(io: Io, side: []const u8, sibling: []const u8, buf: []u8) ?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io, side, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var found: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (!std.mem.startsWith(u8, ent.name, GIT_CRED) or std.mem.eql(u8, ent.name, sibling)) continue;
        if (found != null or ent.name.len > buf.len) return null; // not exactly one
        @memcpy(buf[0..ent.name.len], ent.name);
        found = buf[0..ent.name.len];
    }
    return found;
}

test "a git_push call's token leaves with it: no credentials file outlives a refused push, a dead transfer or a git that never launches" {
    const gpa = std.testing.allocator;
    var threaded = testThreaded(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-gitvc-push-tmp";
    const work = root ++ "/work";
    const side = root ++ "/side";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try testRepo(gpa, io, root, work, side);
    defer test_endpoints = TEST_NOWHERE;

    // Another desk on this data dir has a push running: its credentials file is written, and its git may not have read
    // it yet.
    var sib_buf: [TOKEN_PATH_CAP]u8 = undefined;
    const sibling = tokenPath(io, side, GIT_CRED, &sib_buf).?;
    const sibling_cred = "https://other-desk:the-other-desk's-own-token@github.com\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sibling, .data = sibling_cred });

    const End = enum { refused, dead, no_git };
    const Case = struct { end: End, reply: []const u8 = "", msg: []const u8 };
    const cases = [_]Case{
        .{ .end = .refused, .reply = TEST_FORBIDDEN, .msg = "403" },
        // read, then closed with nothing said
        .{ .end = .dead, .msg = "push failed" },
        // no git on PATH: the credentials file is written, and nothing ever reads it
        .{ .end = .no_git, .msg = "git failed to run" },
    };
    for (cases) |c| {
        var seen: PushSeen = .{ .io = io, .gpa = gpa, .side = side, .sibling = std.fs.path.basename(sibling) };
        var sv: Standin = undefined;
        try sv.start(io, c.reply, .{ .ctx = &seen, .run = PushSeen.look });
        var sv_up = true;
        defer if (sv_up) sv.stop();
        test_endpoints = sv.aimed();
        if (c.end == .no_git) test_endpoints.git = "nl-veil-test-no-such-git";
        const r = push(gpa, io, work, side, "me", "scratch", "gitvc-test", TEST_PAT, "main");
        defer r.deinit(gpa);
        sv.stop();
        sv_up = false;
        test_endpoints = TEST_NOWHERE;
        if (r.ok or std.mem.indexOf(u8, r.msg, c.msg) == null) {
            std.debug.print("\n[{t}] expected a failed push naming \"{s}\", got ok={} \"{s}\"\n", .{ c.end, c.msg, r.ok, r.msg });
            return error.WrongEnding;
        }
        try expectUntouched(gpa, io, sibling, sibling_cred);
        if (c.end != .no_git and !seen.held) {
            // A delete that ran before git started would pass the disk check below and fail every real push.
            std.debug.print("\n[{t}] git ran without its credentials file on disk\n", .{c.end});
            return error.CredentialsNotThereForGit;
        }
        try std.testing.expectEqual(@as(usize, 1), try expectNoTokenOnDisk(gpa, io, side, TEST_PAT, std.fs.path.basename(sibling)));
    }
}

/// Another desk's sweep, run while a push's git waits on the network past the age floor.
const MidPushSweep = struct {
    io: Io,
    gpa: std.mem.Allocator,
    side: []const u8,
    found: bool = false,
    restamped: bool = false,
    removed: usize = 0,
    kept: bool = false,

    fn run(ctx: *anyopaque) void {
        const m: *MidPushSweep = @ptrCast(@alignCast(ctx));
        var name_buf: [64]u8 = undefined;
        const name = ownCredFile(m.io, m.side, "", &name_buf) orelse return;
        m.found = true;
        var pb: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ m.side, name }) catch return;
        // The push has outrun the floor: its file was last written longer ago than any sweep keeps a file for.
        const outran_s: i64 = TOKEN_FILE_STALE_S + 60;
        {
            const f = Io.Dir.cwd().openFile(m.io, path, .{ .mode = .read_write }) catch return;
            defer f.close(m.io);
            const now_ns = Io.Timestamp.now(m.io, .real).nanoseconds;
            f.setTimestamps(m.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = now_ns - @as(i96, outran_s) * std.time.ns_per_s } } }) catch return;
        }
        // The lease re-stamps it within a beat...
        var waited: u32 = 0;
        while (waited < 1000) : (waited += 1) { // ~10 s
            const st = Io.Dir.cwd().statFile(m.io, path, .{}) catch break;
            const age_ns = Io.Timestamp.now(m.io, .real).nanoseconds - st.mtime.nanoseconds;
            if (age_ns < @as(i96, TOKEN_FILE_STALE_S) * std.time.ns_per_s) {
                m.restamped = true;
                break;
            }
            nap.ms(10);
        }
        // ...so a sweep on another desk, now, takes nothing, and git still has its file.
        m.removed = sweepTokenFiles(m.io, m.gpa, m.side, Io.Timestamp.now(m.io, .real).nanoseconds);
        m.kept = if (Io.Dir.cwd().access(m.io, path, .{})) |_| true else |_| false;
    }
};

test "a push that runs past the age floor keeps its credentials file young: another desk's sweep mid-push takes nothing" {
    const gpa = std.testing.allocator;
    var threaded = testThreaded(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-gitvc-lease-tmp";
    const work = root ++ "/work";
    const side = root ++ "/side";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try testRepo(gpa, io, root, work, side);
    defer test_endpoints = TEST_NOWHERE;
    // a beat of 20 ms, so the test waits on a re-stamp rather than a minute
    test_lease_beat_ms = 20;
    defer test_lease_beat_ms = LEASE_BEAT_S * std.time.ms_per_s;

    // git's first request waits on the stand-in, as a push waits on a stalled network, while the file is aged past the
    // floor and another desk's sweep runs.
    var mid: MidPushSweep = .{ .io = io, .gpa = gpa, .side = side };
    var sv: Standin = undefined;
    try sv.start(io, TEST_FORBIDDEN, .{ .ctx = &mid, .run = MidPushSweep.run });
    var sv_up = true;
    defer if (sv_up) sv.stop();
    test_endpoints = sv.aimed();
    const r = push(gpa, io, work, side, "me", "scratch", "gitvc-test", TEST_PAT, "main");
    defer r.deinit(gpa);
    sv.stop();
    sv_up = false;
    try std.testing.expect(!r.ok);

    if (!mid.found) {
        std.debug.print("\ngit's request arrived with no credentials file on disk\n", .{});
        return error.CredentialsNotThereForGit;
    }
    if (!mid.restamped or mid.removed != 0 or !mid.kept) {
        std.debug.print("\nmid-push: re-stamped={} swept={d} file kept={}\n", .{ mid.restamped, mid.removed, mid.kept });
        return error.LeaseLostTheFile;
    }
    // and once the push is over, its file goes with it
    try std.testing.expectEqual(@as(usize, 0), try expectNoTokenOnDisk(gpa, io, side, TEST_PAT, ""));
}

test "git_push authenticates from either desk's data dir: git answers the remote's challenge with the token from a cwd-relative dir and from absolute ones in the OS's separators with a space or a quote, and keeps a tokenless remote" {
    const gpa = std.testing.allocator;
    var threaded = testThreaded(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-gitvc-auth-tmp";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    defer test_endpoints = TEST_NOWHERE;

    // The data dirs the two desks hand the git tools. runGitTool puts the sidecar at `{data}/.veil-desk` (sideDir) and
    // the workdir at `{data}/_chat/builds/{conv}/work`.
    // - The standalone desk's is cwd-relative: desk/src/main.zig seedSettings settles on "data".
    // - The in-process GUI's is `{exe home}/data` (src/main.zig resolvePaths): absolute, with the OS's separators up to
    //   the home, so backslashes on Windows. The home can sit in a business OneDrive folder ("OneDrive - <org>"), with
    //   a space, or under a user folder whose name has a quote.
    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buf[0..try Io.Dir.cwd().realPathFile(io, ".", &cwd_buf)];
    const sep = std.fs.path.sep_str;
    var space_buf: [512]u8 = undefined;
    var quote_buf: [512]u8 = undefined;
    const Case = struct { desk: []const u8, data: []const u8 };
    const cases = [_]Case{
        .{ .desk = "standalone desk", .data = root ++ "/data" },
        .{ .desk = "in-process GUI, a home with a space", .data = try std.fmt.bufPrint(&space_buf, "{s}" ++ sep ++ root ++ sep ++ "OneDrive - Contoso/data", .{cwd}) },
        .{ .desk = "in-process GUI, a home with a quote", .data = try std.fmt.bufPrint(&quote_buf, "{s}" ++ sep ++ root ++ sep ++ "O'Brien/data", .{cwd}) },
    };
    var wrong: usize = 0;
    for (cases) |c| {
        var work_buf: [640]u8 = undefined;
        var side_buf: [640]u8 = undefined;
        const work = try std.fmt.bufPrint(&work_buf, "{s}/_chat/builds/c/work", .{c.data});
        const side = try std.fmt.bufPrint(&side_buf, "{s}/.veil-desk", .{c.data});
        try testRepo(gpa, io, c.data, work, side);

        var sv: Standin = undefined;
        try sv.startChallenging(io, TEST_FORBIDDEN);
        var sv_up = true;
        defer if (sv_up) sv.stop();
        test_endpoints = sv.aimed();
        const r = push(gpa, io, work, side, "me", "scratch", "gitvc-test", TEST_PAT, "main");
        defer r.deinit(gpa);
        sv.stop();
        sv_up = false;
        test_endpoints = TEST_NOWHERE;

        // git read the call's credentials file and answered the challenge with the token, and the refusal that came back
        // is what ended the push.
        if (!std.mem.eql(u8, sv.authorization(), TEST_BASIC_AUTH) or r.ok or std.mem.indexOf(u8, r.msg, "403") == null) {
            std.debug.print("\n[{s}, sidecar {s}] git did not answer the challenge with the token (Authorization: \"{s}\"). The push said ok={}: {s}\n", .{ c.desk, side, sv.authorization(), r.ok, r.msg });
            wrong += 1;
        }
        // The remote git keeps is the tokenless url, and nothing in the repo's config holds the token.
        var cfg_buf: [700]u8 = undefined;
        const config = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.bufPrint(&cfg_buf, "{s}/.git/config", .{work}), gpa, .limited(1 << 16));
        defer gpa.free(config);
        var url_buf: [96]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "url = http://{s}/me/scratch.git\n", .{sv.aimed().web_host});
        if (std.mem.indexOf(u8, config, TEST_PAT) != null or std.mem.indexOf(u8, config, url) == null) {
            std.debug.print("\n[{s}] the repo's config does not keep the tokenless remote ({s}):\n{s}\n", .{ c.desk, url, config });
            wrong += 1;
        }
        // The credentials file left with the call.
        try std.testing.expectEqual(@as(usize, 0), try expectNoTokenOnDisk(gpa, io, side, TEST_PAT, ""));
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

test "the token sweep takes stranded token files, and nothing a live call, the stored token or a model call may need" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const side = "zig-gitvc-sweep-tmp";
    Io.Dir.cwd().deleteTree(io, side) catch {};
    defer Io.Dir.cwd().deleteTree(io, side) catch {};

    // Ages straddle the floor: a minute past it, no call can still need the file; a minute short of it, one may.
    const stale: i64 = TOKEN_FILE_STALE_S + 60;
    const young: i64 = TOKEN_FILE_STALE_S - 60;
    const File = struct { name: []const u8, age_s: i64 = stale, kept: bool };
    const files = [_]File{
        // a call's own file, left by a desk that died mid-call
        .{ .name = ".ghcurlcfg-0123456789abcdef", .kept = false },
        .{ .name = ".gitcred-fedcba9876543210", .kept = false },
        // a git killed while its credential store rewrote the file
        .{ .name = ".gitcred-00112233445566ff.lock", .kept = false },
        // the fixed names builds before 2026-09-17 used, and a lock of one
        .{ .name = ".ghcurlcfg", .kept = false },
        .{ .name = ".gitcred", .kept = false },
        .{ .name = ".gitcred.lock", .kept = false },
        // younger than the floor, so possibly a live call's on another desk: one just written, one a minute short
        .{ .name = ".gitcred-8899aabbccddeeff", .age_s = 0, .kept = true },
        .{ .name = ".ghcurlcfg-aabbccddeeff0011", .age_s = young, .kept = true },
        // never this module's, however old: the stored token, a model call's curl config, the desk's settings
        .{ .name = "github_pat.bin", .kept = true },
        .{ .name = ".chatcurlcfg-0123456789abcdef", .kept = true },
        .{ .name = "settings.json", .kept = true },
        // names that only begin like a token file's: tokenPath writes exactly 16 lowercase hex
        .{ .name = ".gitcredrc", .kept = true },
        .{ .name = ".gitcred-0123", .kept = true },
        .{ .name = ".ghcurlcfg-FEDCBA9876543210", .kept = true },
        // below the sidecar's top level is no call's file, whatever it is called
        .{ .name = "chats/.gitcred-0123456789abcdef", .kept = true },
    };
    const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
    var swept: usize = 0;
    for (files) |f| {
        var pb: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ side, f.name });
        _ = try Io.Dir.cwd().createDirPathStatus(io, std.fs.path.dirname(path).?, .default_dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "https://u:ghp_x@github.com\n" });
        if (!f.kept) swept += 1;
        if (f.age_s == 0) continue;
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = now_ns - @as(i96, f.age_s) * std.time.ns_per_s } } });
    }

    const removed = sweepTokenFiles(io, gpa, side, Io.Timestamp.now(io, .real).nanoseconds);
    var wrong: usize = 0;
    for (files) |f| {
        var pb: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ side, f.name });
        const kept = if (Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
        if (kept == f.kept) continue;
        std.debug.print("token sweep {s} {s}\n", .{ if (kept) "left" else "deleted", path });
        wrong += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
    try std.testing.expectEqual(swept, removed); // the count it reports is the files it took
    try std.testing.expectEqual(@as(usize, 0), sweepTokenFiles(io, gpa, side, Io.Timestamp.now(io, .real).nanoseconds)); // and a second pass finds none
}

test "every token file a git tool writes has a name the sweep knows, and the age floor outlives every call" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The sweep finds strays by isTokenFileName alone, so a name tokenPath produces that it does not match is a token no
    // sweep will ever remove.
    inline for (.{ CURL_CFG, GIT_CRED }) |kind| {
        var a_buf: [TOKEN_PATH_CAP]u8 = undefined;
        var b_buf: [TOKEN_PATH_CAP]u8 = undefined;
        const a = tokenPath(io, "some/dir", kind, &a_buf).?;
        const b = tokenPath(io, "some/dir", kind, &b_buf).?;
        try std.testing.expect(std.mem.startsWith(u8, std.fs.path.basename(a), kind));
        try std.testing.expect(isTokenFileName(std.fs.path.basename(a)));
        // two calls on one sidecar never share a file
        try std.testing.expect(!std.mem.eql(u8, a, b));
    }
    // git's lock of a credentials file holds the token as well
    var c_buf: [TOKEN_PATH_CAP]u8 = undefined;
    var l_buf: [TOKEN_PATH_CAP + LOCK_SUFFIX.len]u8 = undefined;
    const cred = tokenPath(io, "some/dir", GIT_CRED, &c_buf).?;
    try std.testing.expect(isTokenFileName(std.fs.path.basename(try std.fmt.bufPrint(&l_buf, "{s}" ++ LOCK_SUFFIX, .{cred}))));
    // the fixed names earlier builds wrote
    try std.testing.expect(isTokenFileName(".ghcurlcfg"));
    try std.testing.expect(isTokenFileName(".gitcred"));
    // and not the model calls' curl configs, which llm.zig names and sweeps on its own floor
    try std.testing.expect(!isTokenFileName(".chatcurlcfg"));
    try std.testing.expect(!isTokenFileName(".chatcurlcfg-0123456789abcdef"));
    // A sidecar too long for the path buffer gets no name, so the call refuses before writing any token.
    var small: [16]u8 = undefined;
    try std.testing.expect(tokenPath(io, "a/sidecar/dir/longer/than/that", GIT_CRED, &small) == null);
    // repo_create's config outlives no curl...
    try std.testing.expect(TOKEN_FILE_STALE_S > REPO_CREATE_MAX_TIME_S);
    // ...and a live push's credentials file, re-stamped every beat, stays younger than the floor through ten beats in a
    // row that failed to land.
    try std.testing.expect(TOKEN_FILE_STALE_S >= 10 * LEASE_BEAT_S);
}
