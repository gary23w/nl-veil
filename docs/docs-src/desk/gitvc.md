# gitvc

**File:** `desk/src/gitvc.zig`  
**Module:** `desk`  
**Description:** The chat's version-control engine — real git + GitHub for the Veil, built for the classic-tokens-only constraint: a Personal Access Token over HTTPS, no SSH, no OAuth device flow, no `gh` CLI.

---

## Purpose Summary

Gives the desk chat first-class git and GitHub tools (`repo_create` / `git_commit` / `git_push` / `git_status` / `git_log`) instead of leaving a weak model to fumble raw `RUN: git`, encoding the multi-step flow — create the remote *before* pushing — once. Everything runs in the conversation's own `_chat/builds/{conv}/work` directory (a repo per conversation) via `git -C <workdir>`, so no process-wide cwd is touched. Keeping the PAT out of every readable surface is the whole point of the module.

## Key Exports

- `Res` — one operation's result (`ok`, gpa-owned `msg`, `deinit`), folded back into the chat like any tool result.
- `ensureRepo(gpa, io, workdir)` — idempotently `git init -b main` the workdir so it is its *own* repo; an isolated `.git` stops git (and the model's shell) from walking up and committing into a parent repo.
- `status` / `logLine` — `git status --short --branch` and `git log --oneline -n N` (N capped at 50), with friendly no-repo/no-commits messages.
- `commit(gpa, io, workdir, author_name, author_email, message)` — stage-all + commit; auto-init on first use; author set per-commit with `-c` (the machine's global git config is never touched); reports the new HEAD.
- `repoCreate(gpa, io, sidecar_dir, pat, name, private)` — GitHub `POST /user/repos` via curl; the auth header rides in the call's own `-K` config file (`.ghcurlcfg-{16 hex}`), written under `sidecar_dir` right before curl starts and deleted once curl has exited — never on the argv.
- `push(gpa, io, workdir, sidecar_dir, owner, repo, user, pat, branch)` — (re)sets a tokenless `origin` URL and authenticates through the call's own `credential.helper store --file=<tmp>` credentials file (`.gitcred-{16 hex}`), kept young by a lease while git runs and deleted once git has exited; commits nothing itself.
- `isTokenFileName(name)`, `TOKEN_FILE_STALE_S`, `sweepTokenFiles(io, gpa, dir, now_ns)` — which file names are the git tools' token files (a call's own, the fixed `.ghcurlcfg` / `.gitcred` older builds wrote, or a credentials file's `.lock`), the age past which no call can still need one (20 minutes), and the sweep of one dir's top level that chat.zig runs over the sidecar.
- `parseRepoCreate(body) RepoInfo` and `sanitizeRepoName(in, out)` — pure, unit-tested helpers for the GitHub response and an acceptable repo name.

## Dependencies

- `std` (`std.process.run`, `std.Io`, `std.Thread`) plus `log.zig` and `nap.zig` (the lease thread's sleep); at runtime it requires `git` and `curl` on PATH and reports plainly when they are missing.
- The PAT is stored by secrets.zig (PLAINTEXT on every OS — DPAPI survives only as a one-time
  legacy unseal; see the secrets case file) and arrives here as a parameter — this module never
  reads settings or repo-tracked files for it.

## Usage Context

Driven entirely by `desk/src/chat.zig`: `ensureRepo` runs when a chat workdir is created or reopened (before any shell git can run), and the tool dispatcher maps `git_status` / `git_log` / `git_commit` / `repo_create` / `git_push` onto these functions, passing the `{data}/.veil-desk` sidecar as `sidecar_dir`. The chat thread's key sweep (`sweepKeys`, at startup and every ~5 minutes) runs `sweepTokenFiles` over that same sidecar. Operators set the token with `::pat <token>` or the Settings pane.

## Notable Implementation Details

- Token hygiene is triple-layered: never on an argv (curl `-K` file), never in `.git/config` (the persisted remote stays `https://github.com/<owner>/<repo>.git`), and never in output — `scrub()` redacts any error that echoes a credentialed URL (unit-tested).
- **The token leaves with the call.** The curl config and the credentials file are the only places a git tool puts the PAT on disk, in the sidecar inside the data dir, which is often a synced folder. Builds before 2026-09-17 wrote them under the fixed names `.ghcurlcfg` and `.gitcred` and deleted them only in a `defer`, so a desk killed mid-call (a crash, Task Manager, an OS shutdown) left the token there for good, with nothing to remove it. Now each call writes its own file, `{kind}-{16 hex}` (`tokenPath`): two desks on one data dir share the sidecar, and under one fixed name one desk's call ending could delete the file another's call had just written, before its curl or git read it. The delete is armed before the write, so a write that fails halfway or a child that never launches leaves nothing, and `std.process.run` returns only once the child is gone. A delete that fails (a scanner or a sync client holding the file) is logged. `sweepTokenFiles` removes, from one dir's top level, files `isTokenFileName` names that were last written more than `TOKEN_FILE_STALE_S` ago, skipping only directories. The names are strict (the fixed name, or exactly 16 lowercase hex after it) and gitvc's own: the sidecar also holds the stored token and the model calls' curl configs, which are not this module's to delete. git's credential store rewrites its file through `<file>.lock` (which holds the token too), so a credentials file's lock counts as well.
- **The age floor, given a push has no timeout.** A `repo_create` config lives only as long as its curl, which gives up after `REPO_CREATE_MAX_TIME_S` (25 s) and reads the config once, at startup. A push has no timeout at all, so no fixed floor could outlast one, and the chat thread's own sweep can never run during a push (it runs on the thread the push blocks), but another desk on the same data dir sweeps on its own schedule. git reads the credentials file at the remote's first auth challenge and, once a request authenticates, rewrites it through the lock, re-creating it if it is gone (measured with Git for Windows 2.52 against a loopback stand-in). Nothing bounds how long a stalled network holds git before that first challenge, though. So `push` holds a `Lease` while git runs: a thread of its own that re-stamps the file's mtime every `LEASE_BEAT_S` (60 s) and is joined before the file is deleted. The floor is 20 minutes, twenty beats, so a live push's file never looks stranded, even across a run of re-stamps that failed while something held the file. If the desk dies, the stamps stop and the file ages out. A file git itself re-creates after the desk died (an orphaned push that finished) is simply swept later.
- The workdir-isolation guard exists because a live failure was observed: with the data dir inside nl-veil's own source tree, a shell `git add -f` force-committed a workdir file past `.gitignore` into the source repo.
- `git()` captures bounded stdout/stderr and hands back whichever is substantial — git writes most human output to stderr.
- Nine test blocks. Four cover `sanitizeRepoName`, `parseRepoCreate`, `scrub`, and the minimal `jsonStr` field extractor. Five cover the token files, running the real curl and git against a stand-in listening on 127.0.0.1 only and reading back a real temp dir: a `repo_create` that creates, is rejected, meets a dead transfer, or has no curl to run; a push that is refused, meets a dead transfer, or has no git to run; a push held past the floor while another desk's sweep runs; the sweep's choice of files; and the names and the floor against the real constants. A call's endpoints and programs come from `test_endpoints` in a test build only, which points at a closed loopback port until a test aims it at its stand-in.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
