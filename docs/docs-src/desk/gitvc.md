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
- `repoCreate(gpa, io, sidecar_dir, pat, name, private)` — GitHub `POST /user/repos` via curl; the auth header rides in a `-K` config file written under `sidecar_dir` and deleted immediately — never on the argv.
- `push(gpa, io, workdir, sidecar_dir, owner, repo, user, pat, branch)` — (re)sets a tokenless `origin` URL and authenticates through a one-shot `credential.helper store --file=<tmp>` credentials file, deleted right after; commits nothing itself.
- `parseRepoCreate(body) RepoInfo` and `sanitizeRepoName(in, out)` — pure, unit-tested helpers for the GitHub response and an acceptable repo name.

## Dependencies

- `std` only (`std.process.run`, `std.Io`) plus `log.zig`; at runtime it requires `git` and `curl` on PATH and reports plainly when they are missing.
- The PAT is stored by secrets.zig (PLAINTEXT on every OS — DPAPI survives only as a one-time
  legacy unseal; see the secrets case file) and arrives here as a parameter — this module never
  reads settings or repo-tracked files for it. gitvc.zig's own header still says "sealed at rest";
  that comment is stale (harness ledger H14).

## Usage Context

Driven entirely by `desk/src/chat.zig`: `ensureRepo` runs when a chat workdir is created or reopened (before any shell git can run), and the tool dispatcher maps `git_status` / `git_log` / `git_commit` / `repo_create` / `git_push` onto these functions. Operators set the token with `::pat <token>` or the Settings pane.

## Notable Implementation Details

- Token hygiene is triple-layered: never on an argv (curl `-K` file), never in `.git/config` (the persisted remote stays `https://github.com/<owner>/<repo>.git`), and never in output — `scrub()` redacts any error that echoes a credentialed URL (unit-tested).
- The workdir-isolation guard exists because a live failure was observed: with the data dir inside nl-veil's own source tree, a shell `git add -f` force-committed a workdir file past `.gitignore` into the source repo.
- `git()` captures bounded stdout/stderr and hands back whichever is substantial — git writes most human output to stderr.
- Four test blocks cover `sanitizeRepoName`, `parseRepoCreate`, `scrub`, and the minimal `jsonStr` field extractor.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
