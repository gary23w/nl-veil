# the veil — v1.1.2

**A point release about secrets on disk, and about work that reaches you.** Nothing in v1.1.0's shape changed
and nothing needs migrating. What changed is that a running call no longer leaves your API keys and GitHub
tokens lying in your data folder, that a hive's output now arrives at the machine that asked for it in the
cases where it used to vanish, and that a call whose transfer dies gives up in milliseconds instead of minutes.
Most of this came out of reading the code that v1.1.1's own notes admitted had never been read end to end.

**The one to act on.** Every build before this one wrote each hosted model call's `Authorization: Bearer <key>`
into a small curl config file next to your conversation and never deleted it. On the machine this was found on,
**111 of those files were still there**, the oldest from July, in a folder that syncs to OneDrive. v1.1.2 writes
no such file at all — the config goes to curl over a pipe — and sweeps the ones older builds left behind.
**If you ran an earlier build with a long-lived provider key, rotate it.** See *Upgrading* below.

**The one you will notice.** A cast you fire from the desktop, in a sub-chat or from a scheduled task, now shows
its run and delivers its files. Before, the desk looked for the run under a name the server never used, so the
row sat at *deploying* until it timed out and its **Stop** button reached nothing.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.1.2-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.1.2-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.1.2-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.1.2-linux-x86_64.zip`** |

Unzip it, then run **`veil.exe`** (Windows) or **`./veil`** (macOS/Linux). That single action starts the
server *and* opens the app.

> **Do NOT download "Source code (zip / tar.gz)"** at the bottom of this page. GitHub attaches those to every
> release automatically — they're the raw repo, and building from them needs the Zig compiler.
>
> The `veil-server-*` files are the **headless** server for remote boxes and containers — no desktop app.
> Most people don't want these.

**Unsigned build:** these binaries aren't code-signed, so Windows shows *"Windows protected your PC"* (click
**More info → Run anyway**) and macOS says the developer can't be verified (**right-click → Open**, or
`xattr -dr com.apple.quarantine <folder>`). Signing certificates are still on the list.

## Upgrading from v1.1.1

Nothing to migrate: same data directory, same Cloudflare login, no new scopes, no second sign-in. Two things
are worth doing once.

- **Rotate any long-lived provider key or GitHub token you used with an earlier build.** Those builds left the
  key inside `.curlcfg-*` / `.streamcfg-*` files in each conversation's folder, and the desk left its own in
  `.veil-desk/.chatcurlcfg`; the git tools did the same with a GitHub PAT. If your data directory syncs to a
  cloud drive, as the one this was found on does, copies went with it. The first start of this build sweeps the
  stranded files, but a key that has already been synced is a key that has left the machine.
- **The old files are swept, not shredded.** The sweep deletes them through the filesystem; on OneDrive that
  leaves copies in the recycle bin for about 30 days.

New here? The [v1.1.0 notes](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.0.md)
explain what the veil is, and the [v1.1.1 notes](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.1.md)
cover memory and staying power. This page is only what changed since.

---

## What's new since v1.1.1

### No secret is written to disk to make a call

Curl takes its arguments from a config file, and that is how every secret in this codebase reached it: the
model key, the Cloudflare bearer, the GitHub token. The file was written into the caller's own working folder,
named per tag, and nothing deleted it. Four separate paths did it, and all four are gone.

**The model key never becomes a file.** Both curl clients — the server's and the desktop's — hand curl its
config on **stdin** (`-K -`), so the key exists only in a pipe between two processes for the length of the
call. There is no path to name, nothing to sync, nothing to sweep afterwards, and a killed process strands
nothing. Where a file is genuinely unavoidable (a request body too large for the pipe), the body goes to a file
and the key still does not.

**The Cloudflare bearer rides the same pipe.** `cf_oauth` is the one transport for every Cloudflare call — the
token legs, the API calls behind `cf_r2` and `cf_tunnel`, and the `cf_` tool belt — and its bearer, with any
request body that fits beside it, now goes over stdin too.

**A key cannot smuggle curl an option.** A config line is `header = "Authorization: Bearer <key>"`, and a key
holding a quote and a newline could close that line and add options of its own — including one that writes the
key to a URL of the attacker's choosing. Keys are refused if they carry a byte a config value cannot hold, at
the point they are saved and again at the point they are used, and the escaping lives in one place both
clients call.

**GitHub tokens too.** The desk's git tools wrote the PAT to `.ghcurlcfg` / `.gitcred` and left them. Each is
per call and deleted when its child exits; a push holds its credentials file open only while git is running;
the chat thread sweeps strays older than 20 minutes; and a stored token with a byte no GitHub token has is
refused before anything is written, which closes the same injection shape as above.

**And git stopped asking people for credentials.** A push whose credentials were missing made git ask — on
Linux and macOS on the desk's own controlling terminal, which meant a desk started from a terminal sat there
with its chat thread blocked until something killed it. Every git child the tools spawn now runs with terminal
prompts off and no askpass program, so a push that cannot authenticate fails in milliseconds with git's own
message. The micro-console's children get the same treatment on the AI door; the **You** tab keeps its
credential dialog on purpose, because that door is you.

While fixing the above: `git_push` never actually authenticated on Windows, or from a standalone desk anywhere —
git could not read the credentials file at the path it was handed. It reads it now.

### A hive's work reaches the machine that asked for it

A cast writes its files on the server. When your desktop (or `veil chat`) is not sharing that folder, the
engine pushes them to you when the run ends. Five separate things could stop that from happening, and each of
them is fixed:

- **Sub-chats and scheduled runs were looked for under the wrong name.** A sub-chat builds in its primary's
  folder and a scheduled run under its task, but the desk and parts of the server looked for a folder named
  after the conversation. A desk-fired cast in a sub-chat failed at its deadline with *the run directory never
  appeared*, a server-fired one never showed a run at all, and **Stop** reached nothing.
- **A conversation's second cast never delivered.** The push marks a run as delivered once; nothing ever
  cleared that mark, so every later cast into the same folder returned at the mark and pushed nothing.
- **A crashed worker's relaunch lost its output.** When a worker died and the supervisor relaunched it into the
  same folder, a push in the gap could mark the half-finished run delivered. The waits now ask the supervisor
  whether a relaunch is coming, and a worker entering a folder clears the mark.
- **A re-cast that was refused still destroyed the previous run.** Deploy reset the folder — DONE marker,
  events — before it had resolved a model or a credential, so *"no model to run this on"* left the finished
  previous run stripped. The reset happens after those checks now.
- **After a restart, runs that shared a name were dropped.** Re-adopted runs were keyed by folder name, and a
  scheduled run's name is the minute it started, so two tasks in the same minute collided and the second was
  never adopted: unsupervised, and 404 on stop or delete. Names are qualified now, and a run-dir name only ever
  resolves inside the account that asked.

**Retention stopped deleting your conversations.** The old cleanup walked for `events.jsonl` recursively and
treated any folder holding one as a run, so `_chat/convs/<conv>` — your actual conversation, transcript and all —
was deleted whole after 14 idle days, and hive files inside a run's `work/` tree became phantom runs that a
delete could strip. Reattach and retention now walk only the three shapes the server actually spawns into.
The consequence is deliberate and worth knowing: **nothing prunes old conversations any more.** See
*Known limitations*.

**The Swarm tab tells the truth.** It lists scheduled-run casts (it never walked that tree), keeps the newest
runs rather than the first 64 the filesystem happened to return, deletes a scheduled run by its conversation
instead of by the minute-stamp its siblings share, and gives a row back the moment a delete fails instead of
leaving it stuck at *deleting…* until restart. A swarm id longer than 64 bytes no longer crashes the desk —
a scheduled run's id is about 69.

### A call that cannot finish stops waiting

- **Concurrent calls no longer send each other's prompts.** A call wrote its request body to a file named after
  its tag, in the folder it shared with its siblings, and curl read that file when it started. Swarm minds, the
  scouts, and a sub-chat family's turns all run same-tag calls in one folder at once, so one call could send
  another's prompt. Nothing failed; the answer simply came back to the wrong question. Every call names its own
  body now, and the tag keeps a whole copy of the last one so replaying a captured request still works.
- **A dead transfer is noticed at once.** If curl died before its transfer — a missing config, a killed
  process — the streamed reader kept waiting for an end marker that was never coming: about 4½ minutes on the
  server, 5 to 15 on the desk. Both now ask whether curl has exited before each read and fall back immediately.
- **Stopping or pruning a cast no longer breaks a call running in it.** The cleanup deleted every config in the
  folder, including one a live call's curl had not read yet.
- **Errors stopped leaking.** Twenty formatted error messages were handed to helpers that copy them and never
  freed; the drift check that was supposed to catch that shape could not see it, and now can.

### Windows and Linux

- **Two servers could share one port on Windows.** Neither Zig's listener nor httpz's failed on a port another
  process held, so a second veil booted silently beside the first, took none of the traffic, and inherited the
  port when the first died. The listener binds exclusively now, a second instance exits with *AddressInUse*, and
  the engine endpoint and browser broker stop racing each other for fixed ports.
- **A stopped server crashed the Linux build's tests.** httpz freed its worker thread pool without waiting for
  the threads, which then faulted on freed memory. The pool is joined before anything it uses is freed. (This
  one was caught by CI on the first merge that exercised it, and fixed the same hour.)
- **The freeze class is closed on both sides.** The last threads sleeping on the Io runtime's per-thread alert —
  the model unloader, the turn pulse, the tunnel, the retry and rate waits, the CLI and the worker loop — sleep
  on the OS instead, where a stray wake cannot corrupt them. On Windows the loopback HTTP client's timeout now
  covers its connect, so a dead address can no longer hold a desk worker for a minute.
- **`stop()` closes each connection exactly once.** The old sweep could close a socket a handler had already
  closed, which on Windows can hit an unrelated reused handle.

### Everything v1.1.1 wrote down as *found* is fixed

That release ended with five things it had noticed and not fixed. All five are fixed here:

- the `cf_` tool belt **works from the desktop and `veil chat`** now — every call runs in the server, which is
  the only process holding your token, and the one file a call touches is carried across;
- the desk freeze fix is complete, as described above;
- a tunnel **hostname change** moves its DNS record and Access app instead of leaving the new name unreachable,
  and a quick tunnel never claims Access protection it does not have;
- the **R2 backup re-creates its bucket** when it is gone, so a login to a different account keeps backing up;
- the **byte-order mark** is stripped by the `get_credential` and `recall` tools too.

### The oracle and the docs

- The acceptance script used to rerun a whole suite standalone whenever a test wrote anything to stderr, which
  every green run does. Worse, its first-match rule could turn a real failure green. A gate that exits 0 is
  never rerun now, and the rerun that remains is for a runner that lost its test process.
- The drift scan learned two leak shapes it was blind to and stopped flagging byte classifiers that produce no
  escapes.
- Every module has a current page on the [docs site](https://gary23w.github.io/nl-veil/), and the desk poller's
  page describes its real exports, its log rotation and its key re-reads rather than the shape it had a release
  ago.
- The daily models.dev sync landed its second batch.

---

## Known limitations

The [v1.1.0 list](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.0.md#known-limitations)
still holds in full — unsigned binaries, no HTTPS on the LAN, listening on every interface by default, admin is
in effect a shell on the host, and the tool belt wants Python on `PATH`. So does v1.1.1's note that the recall
overlay and the facts ledger are pinned by tests and **not yet measured on a live marathon run**. Additions
about this release's own work:

- **Nothing prunes old conversations.** Retention deleting them was the bug fixed above; no replacement rule
  ships here, so `_chat/convs/` grows until you delete something yourself. Run directories are still pruned.
- **Most of this is oracle-green, not observed live.** The cast, sync, restart and retention work is pinned by
  tests against stand-ins and temp directories; it has not been run against a live server on a second machine.
- **The desk's own stranded key files go on its first start after this build**, not on upgrade — the sweep runs
  in the rebuilt desk.
- **Prompts are off for git, not for everything.** A program git runs itself (ssh, gpg) has prompts of its own,
  and the exec tool's children are not covered. The **You** console door keeps its credential dialog by design.
- **One scratch file still lands in your workspace:** the vision call in the image tool writes its request body
  into the conversation's `work/` folder.

### Found while writing these notes

None of these is new in this release, and none is fixed in it.

- **The strict build gates read a warning as a broken build.** `check.sh`'s build gates grep for lines Zig also
  prints when a *succeeding* compile step's compiler wrote to stderr, so a C or linker warning would read as a
  failure there.
- **A file that cannot be read still costs a call its full timeout in one place:** if the desk's curl cannot
  read a body it was given, the call waits out its first-byte timeout rather than failing at once.
- **The cast cleanup still deletes every `.curlcfg-*` in a folder.** It is harmless now that no call writes
  one, and it will keep taking older builds' leftovers, but the rule itself is still shaped around files that
  no longer exist.

---

**Gate at the tag:** 824 of the server suite's 825 tests pass and all 268 desk tests pass — the one skip is a
Linux-only test, and the same server suite cross-compiled for x86_64-linux runs there with 797 passed and 28
skipped, none failed. Both the server-only and the full GUI builds complete. `scripts/check.ps1 -Full`, ALL
GREEN, with the drift scan reporting nothing actionable.

*Full changelog: [`v1.1.1...v1.1.2`](https://github.com/gary23w/nl-veil/compare/v1.1.1...v1.1.2)*
