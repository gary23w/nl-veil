# bounded

**File:** `desk/src/bounded.zig`  
**Module:** `desk`  
**Description:** The desk package's copy of the server's bounded child run: one deadline for the whole run, the child's whole tree killed at it or past an output limit, and on Windows the pending pipe reads cancelled before the reader is torn down.

---

## Purpose Summary

The desk ran git, curl, neuron-db and its own `veil` verbs through Zig 0.16's `std.process.run`, which on Windows is no bound: its `.timeout` waits out a child that prints nothing, and its output limits can hang outright when the child keeps writing one stream while the other stays silent. This file is the server's `src/worker/bounded.zig`, which explains both in full; see that case file (WK-35) for the mechanism, the exports and the tests.

## Dependencies

- `std`, `builtin` — nothing else from the desk package
- TWIN: `src/worker/bounded.zig` — the server package's copy

## Usage Context

- `chat.zig` — `answerSyncRequest` and `answerFilePull` run `veil sync-manifest` / `veil sync-read` under 50 s, inside the 60 s the server waits for the answer; a run that does not finish posts the empty answer, as a failed spawn always did
- `gitvc.zig` — every `git` call (600 s; output past 64 KB or messages past 16 KB stop git and say so) and repo_create's curl (its `--max-time` + 15 s)
- `neuron.zig` — every neuron-db run (120 s, answers past 256 KB read as none, as before)
- `updater.zig` — `command`, under the seconds each caller gives it, failing with the same errors as before (`Timeout`, `StreamTooLong`, `DownloadOrProcessFailed`, or the spawn's own)

Registered directly in `desk/src/tests.zig`, so the real-shell tests run in the desk suite too.

## Notable Implementation Details

- TWIN, and how it stays one: the file is byte-identical to `src/worker/bounded.zig`, header included, and the header says why: the desk is compiled into `veil` as a module of its own, and a source file may belong to exactly one module, so the desk cannot import the server's copy. `scripts/check.ps1 -Scan` and `scripts/check.sh --scan` compare the two whole files under `[twins]`. To keep the file the same in both packages it imports only `std` and `builtin`; the test that tied a missing program's spawn error to `deps.isSpawnMissing` lives in the server's `deps.zig`.
- Desk tests over it: `gitvc.zig` runs a real `git diff --no-index` past the 64 KB limit, and `updater.zig` runs a real shell silent for ~10 s under a 1 s bound and proves the shell's child dead with `expectTreeGone`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
