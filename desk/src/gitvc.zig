//! gitvc.zig — the chat's VERSION-CONTROL engine. Gives the Veil real git + GitHub, built for the constraint
//! that matters where nl-veil actually runs: CLASSIC TOKENS ONLY. No SSH, no OAuth device flow, no dependence on
//! the `gh` CLI (any of which are blocked or absent in restricted regions) — just a Personal Access Token over
//! HTTPS, which works anywhere `git` + `curl` do.
//!
//! SECURITY is the whole point (the moltbook run pasted a PAT straight into the chat transcript). The token here:
//!   * is stored sealed via secrets.zig (DPAPI on Windows), never in settings.json or any repo-tracked file;
//!   * NEVER rides on an argv (visible in the process list) — repo creation puts it in a curl `-K` config file
//!     (the exact trick llm.zig uses for the model key), deleted immediately after the call;
//!   * NEVER lands in `.git/config`'s remote URL or the transcript — push authenticates through a one-shot
//!     `credential.helper store --file=<tmp>` credentials file that is written 0600-ish and deleted right after,
//!     while the persisted remote stays tokenless (`https://github.com/<owner>/<repo>.git`).
//!
//! Everything runs in the conversation's own `_chat/builds/{conv}/work` dir (a repo per conversation), via
//! `git -C <workdir>` so no process-wide cwd is touched. The Veil drives it through first-class tools
//! (repo_create / git_commit / git_push / git_status / git_log) rather than raw `RUN: git`, so the multi-step
//! flow — create the remote BEFORE pushing — is encoded once instead of fumbled by a weak model each time.

const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");

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
    av.appendSlice(gpa, &.{ "git", "-C", workdir }) catch return .{ .ok = false, .out = gpa.dupe(u8, "oom") catch @constCast("oom") };
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
/// can walk UP to a parent repo and commit into it. This is load-bearing: observed live, with the data dir
/// living inside nl-veil's own source tree, a shell `git add -f` force-committed a workdir file past .gitignore
/// straight into the source repo. An isolated `<workdir>/.git` makes git stop there. Idempotent — a no-op once
/// the repo exists. Best-effort: a failure just leaves the pre-existing behavior.
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

/// Create a GitHub repo via the REST API using the PAT. The token rides in a curl `-K` CONFIG FILE (auth header),
/// NEVER on the argv — the file is written under `sidecar_dir`, used, and deleted immediately. Returns the parsed
/// repo info (clone/html url) or an error message. `name` is used verbatim (caller sanitizes).
pub fn repoCreate(gpa: std.mem.Allocator, io: Io, sidecar_dir: []const u8, pat: []const u8, name: []const u8, private: bool) Res {
    if (pat.len == 0) return res(gpa, false, "no GitHub token configured — set one with `::pat <token>` (or the Settings pane) first. It is sealed at rest and never written to the transcript.", .{});
    if (name.len == 0) return res(gpa, false, "a repository name is required.", .{});
    // curl config: the auth header (with the PAT) lives here, off the argv. Deleted in defer.
    const cfg_path = std.fmt.allocPrint(gpa, "{s}/.ghcurlcfg", .{sidecar_dir}) catch return res(gpa, false, "oom", .{});
    defer gpa.free(cfg_path);
    const cfg = std.fmt.allocPrint(gpa, "header = \"Authorization: token {s}\"\nheader = \"Accept: application/vnd.github+json\"\nheader = \"User-Agent: nl-veil\"\n", .{pat}) catch return res(gpa, false, "oom", .{});
    defer gpa.free(cfg);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = cfg }) catch return res(gpa, false, "could not stage the request", .{});
    defer Io.Dir.cwd().deleteFile(io, cfg_path) catch {};
    const payload = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"private\":{s},\"auto_init\":false}}", .{ name, if (private) "true" else "false" }) catch return res(gpa, false, "oom", .{});
    defer gpa.free(payload);
    const argv = [_][]const u8{ "curl", "-sS", "--max-time", "25", "-K", cfg_path, "-X", "POST", "https://api.github.com/user/repos", "-d", payload };
    const r = std.process.run(gpa, io, .{ .argv = &argv, .stdout_limit = .limited(64 << 10), .stderr_limit = .limited(8 << 10) }) catch return res(gpa, false, "curl failed to run — is curl installed?", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const info = parseRepoCreate(r.stdout);
    if (info.ok) return res(gpa, true, "created {s} — {s}\n(remote will be set on the next git_push)", .{ info.full_name, info.html_url });
    const why = if (info.err.len > 0) info.err else std.mem.trim(u8, r.stderr, " \r\n\t");
    return res(gpa, false, "GitHub rejected the repo create: {s}", .{if (why.len > 0) why else "unknown error (check the token's `repo` scope)"});
}

/// Push the conversation's repo to `owner/repo`. The remote is (re)set TOKENLESS
/// (`https://github.com/<owner>/<repo>.git`); the PAT is supplied through a one-shot git credentials file
/// (`credential.helper store --file=<tmp>`), written under `sidecar_dir` and deleted immediately — so the token
/// never touches the argv, `.git/config`, or the transcript. Auto-commits nothing; caller commits first.
pub fn push(gpa: std.mem.Allocator, io: Io, workdir: []const u8, sidecar_dir: []const u8, owner: []const u8, repo: []const u8, user: []const u8, pat: []const u8, branch: []const u8) Res {
    if (!isRepo(io, gpa, workdir)) return res(gpa, false, "nothing to push — commit something first (git_commit).", .{});
    if (pat.len == 0) return res(gpa, false, "no GitHub token configured — set one with `::pat <token>` first.", .{});
    if (owner.len == 0 or repo.len == 0) return res(gpa, false, "no remote yet — run repo_create (or tell me the owner/repo) before pushing.", .{});
    const br = if (branch.len > 0) branch else "main";
    // remote 'origin' = tokenless https url (idempotent: set-url, else add)
    const remote_url = std.fmt.allocPrint(gpa, "https://github.com/{s}/{s}.git", .{ owner, repo }) catch return res(gpa, false, "oom", .{});
    defer gpa.free(remote_url);
    const su = git(gpa, io, workdir, &.{ "remote", "set-url", "origin", remote_url });
    gpa.free(su.out);
    if (!su.ok) {
        const ad = git(gpa, io, workdir, &.{ "remote", "add", "origin", remote_url });
        gpa.free(ad.out);
    }
    // one-shot credentials file (deleted in defer). `credential.useHttpPath=false` so one entry covers the repo.
    const cred_path = std.fmt.allocPrint(gpa, "{s}/.gitcred", .{sidecar_dir}) catch return res(gpa, false, "oom", .{});
    defer gpa.free(cred_path);
    const un = if (user.len > 0) user else owner;
    const cred = std.fmt.allocPrint(gpa, "https://{s}:{s}@github.com\n", .{ un, pat }) catch return res(gpa, false, "oom", .{});
    defer gpa.free(cred);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = cred_path, .data = cred }) catch return res(gpa, false, "could not stage credentials", .{});
    defer Io.Dir.cwd().deleteFile(io, cred_path) catch {};
    var helper_buf: [700]u8 = undefined;
    const helper = std.fmt.bufPrint(&helper_buf, "credential.helper=store --file={s}", .{cred_path}) catch return res(gpa, false, "path too long", .{});
    const g = git(gpa, io, workdir, &.{ "-c", "credential.useHttpPath=false", "-c", "credential.helper=", "-c", helper, "push", "-u", "origin", br });
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
