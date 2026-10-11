# the veil v1.1.18

The veil stops charging your machine for memory it never uses. On Windows the idle app charged 4.7 GB to the machine's commit limit before its first request; it now charges about 330 MB. The training-set recorder no longer makes Windows Defender re-read half-gigabyte files after every model call, and the app now reports its own memory, threads and Defender's reads in its log.

## Why

Users reported the desk lagging, and the whole machine stalling after a prompt. Measured on 2026-10-11 on a 32 GB Windows machine:

- **4.7 GB of commit at idle.** Zig 0.16's `std.Thread.spawn` on Windows hands its stack size, 16 MiB by default, to `NtCreateThreadEx` as the stack *commit*. The 148 threads that used the default each charged 16 MiB the moment they started: 2.37 GB. httpz, in its blocking mode, preallocated one 16 MiB request buffer for each of its 128 workers: 2.18 GB more. On a machine already near its commit limit, the app alone took it from 36.6 to 41.6 GB of a 45.6 GB limit.
- **Defender rescanning the training set.** With the training-set recorder left on since August, every model call appended a few dozen KB to `raw.jsonl`, `sft.jsonl` and the per-model files, which had grown to about 500 MB each. Windows Defender re-reads a file in full each time it is modified and closed: about 45 bursts of roughly 1 GB in the 150 seconds around one prompt.
- **Server logs went nowhere.** In app mode the server shares a GUI process whose stderr is attached to nothing, so every server warning and error was silently lost.

## What changed

- **Thread stacks commit 256 KiB, not 16 MiB.** Every thread starts through one helper (`src/threads.zig`, with a desk twin and the same config in vendored httpz). It commits 256 KiB and keeps the executable's 16 MiB reserve, so a thread still grows to the same depth on demand, page by page, as the main thread always has. A test recurses 8 MiB deep on a 256 KiB-commit thread. The async runtime's pools get the same stack size. POSIX keeps the std default, since a pthread stack is mapped rather than committed there.
- **A small shared request-buffer pool.** httpz keeps 16 pooled buffers of 256 KiB instead of 128 of 16 MiB. A larger request, or one that arrives while all 16 are lent out, gets a buffer of its own for that request, so 16 MiB image uploads still work.
- **Measured result:** the idle app went from 4,703 MB to 327 MB of commit with the same 160 threads. Its thread stacks went from 2,373 MiB to 54 MiB.
- **Every thread has a name.** Threads are named `veil:<role>` (`veil:http`, `veil:chat-turn`, `veil:desk-poller` and so on), so a debugger, Process Explorer or the vitals line can say which role owns which thread.
- **Rolling training-set parts.** No recorder file still being written grows past 16 MiB. The append that would cross it renames the file to `<name>.<UTC stamp>-<seq>-t<thread>.jsonl` and starts a fresh one. Records are byte-identical and never split; concatenate the parts in name order, then the live file. A Defender rescan now reads at most 16 MiB.
- **Vitals.** Every 5 seconds the app samples its own commit charge, working set, threads by name, handles and I/O, the machine's commit charge and free RAM, and Defender's read bytes. It logs one line a minute and warns the moment Defender reads 256 MiB, its own commit grows 128 MiB, its thread count jumps by 16, free RAM drops under 1 GiB, or the machine reaches 95% of its commit limit. Admins can read the last 10 minutes at `GET /api/v1/vitals`.
- **Server logs reach `veil-desk.log` in app mode**, tagged `srv(<scope>)`, instead of being lost.
- **The sentry.** The veil can act as a firewall and blue-team watch for the machine it runs on. It inventories listening ports, outbound connections and persistence (Run keys, scheduled tasks, services), adopts the first scan as its baseline, and reports what changes after that. The watch loop spends no tokens: it runs OS commands and compares text. Admin turns get six `sentry_*` tools, and there is a `veil sentry` command. The default posture only observes; enforcing firewall rules needs an elevated veil and says so when it is not. It is unit-tested and was smoke-tested on a scratch server. Enforcement from an elevated veil, and the Linux and macOS firewall backends, have not run live yet.
- **The tool tree is on by default.** v1.1.16 shipped it as an opt-in. With Agent Garrett on, a one-word first message carried 227 flat tool definitions, about 48k tokens, on every model call. On the map the same belt is about 12 to 16 KB. `NL_TOOL_MAP=0` restores the flat belt.
- **Desk keyboard order.** Tab and Shift+Tab walk every text field and button in draw order. Tab leaves a text field cleanly, and switching tabs drops a focus ring that belonged to the old tab's body.
- **The desk draws less while you are in another window.** An unfocused desk presents a frame only when something is changing, at most ten a second, and not while the window is covered or the machine has been idle for a minute. `NL_DESK_FRAMELOG=1` writes a frame-timing line every 5 seconds.
- **Lineage counts in one memory-engine process per lineage** (from v1.1.17, which was withdrawn before publication). Seven lineages launch seven processes per refresh instead of 63. Bundles pin Neuron commit `5db2c039bf8f20349299e64650aea2d6a2fce911`, which adds the `stats-batch` command; source builds need that revision too.
- **Microsoft Store packaging** (`scripts/package-store.ps1` and the Windows Store workflow) and a privacy page, from the Store work merged since v1.1.16. A Store install keeps its data in the package's LocalState folder and leaves updates to the Store.

## What it does not fix

The rest of a busy machine. On the test machine, after this fix, the remaining stalls came from other software. Defender re-scanned a 318 MB binary that another desktop app relaunched every few seconds, about 1 GB of reads each time, and the Windows Search indexer read several GB in bursts. Neither involved the veil: its own child processes coincided with no Defender reads at all. The vitals line now reports Defender's reads, so this is visible from the veil's own log.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release tree: the server suite (957 passed, 1 Linux-only skip, 0 failed), the desktop suite (312 of 312), the Linux test cross-compile, the server-only and full GUI builds, the catalog and web-asset checks, and both tater-tot runtime suites. `check.ps1 -Scan` reports no drift, and its new thread rule finds no thread left on the 16 MiB default.

An independent review of the diff in four areas (thread stacks, request buffers, the log hook and vitals) raised ten findings. The eight that survived adversarial verification, all low severity, are fixed in this release, with tests where they apply: a long log line's pieces are written under one lock, a desk with no window stops routing server lines into a buffer nothing flushes, Linux reports no commit-limit warning when its overcommit mode enforces none, and macOS starts no vitals thread it cannot feed. The vitals module's tests also pass on Linux under WSL, and it compiles for macOS.

Live, on the test machine, with release builds against a real data folder:

- Idle commit: 4,703 MB before and 327 MB after, both with 160 threads. Thread stacks: 2,373 MiB before and 54 MiB after, read per thread from each stack's committed pages.
- A chat turn with a tool call added about 16 MB of commit. Its three extra threads exited when it finished.
- Per second, against every new process: no veil child process (curl, neuron) coincided with a Defender read burst.
- The vitals line appeared in `veil-desk.log` within seconds of launch and reported the same commit, thread and Defender numbers the external probes did.

## Switches

| variable | effect |
|---|---|
| `NL_VITALS` | on by default; `0` or `off` turns the vitals sampler off |
| `NL_VITALS_LOG_S` | seconds between vitals lines, default `60` (5 to 3600); spikes log at once |
| `NL_TOOL_MAP` | the tool tree, now on by default; `0` or `off` restores the flat belt |
| `NL_DESK_FRAMELOG` | `1` writes a desk frame-timing line every 5 seconds to `veil-desk.log` |
| `NL_SENTRY`, `NL_SENTRY_EVERY` | seed the sentry on, and set its scan interval in seconds |

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. If you installed v1.1.17 before it was withdrawn, this update replaces it. For a new installation, download the complete bundle from the [v1.1.18 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.18), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.16...v1.1.18) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## Licenses and corresponding source

NL-Veil code uses its [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.18/LICENSE). Gary includes modified [ARTEX](https://github.com/Hinln/ARTEX) source under [AGPL-3.0](https://github.com/gary23w/nl-veil/blob/v1.1.18/cloud/GARY-LICENSE). The [Gary notice](https://github.com/gary23w/nl-veil/blob/v1.1.18/cloud/GARY-NOTICE), [source archive](https://github.com/gary23w/nl-veil/raw/refs/tags/v1.1.18/cloud/gary-source.tar.gz), and [Cloudflare build sources](https://github.com/gary23w/nl-veil/tree/v1.1.18/cloud) are public and included in every full release bundle. Dependencies retain their own licenses.
