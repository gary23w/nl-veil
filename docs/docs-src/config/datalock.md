# datalock

**File:** `src/config/datalock.zig`  
**Module:** `config`  
**Description:** One server per data dir, enforced: the lock every veil takes on `<data>/.veil.lock` before it serves a data dir, held by the operating system for as long as the process lives, and readable by the next start so it can name the holder's pid, port and bind address.

---

## Purpose Summary

Measured twice on 2026-10-14 (data/veil-desk.log, UTC 20:18 and 22:38): a server-only veil was serving a long turn on 127.0.0.1:8787 when the desk app was started on the same data dir. The desk's in-process server bound 0.0.0.0:8787 beside it, the first listener stopped answering for about 15 s, and from then on the second server answered the first one's client out of the shared data dir while the original turn was dead. Both shared the vault, the OAuth token and files.jsonl for minutes; an earlier run of the same collision overwrote data/.desktop_key (2026-09-22). The port is not the guard, because Windows let the second bind succeed beside the first. The data dir is.

The lock is the operating system's, not a pid file's. On Windows the holder opens the file sharing READ only, so a second open for writing is refused with a sharing violation for as long as any process holds it, and the handle dies with the process. On POSIX it is `flock(LOCK_EX|LOCK_NB)` on the open file, released by the kernel when the holder exits however it exits. Either way a crash leaves a file nobody holds, and the next start takes it: the pid written inside is for the refusal message, never the gate. A reader may always open the file for reading, so the refusal can say who holds the dir.

Not a byte-range lock (what std's `lock = .exclusive` does on Windows through NtLockFile): that lock is mandatory for every other handle, so the second veil could not read the pid and port it is being refused for.

## Key Exports

- `FILE_NAME` — `.veil.lock`, the file under the data dir.
- `take(io, data_dir, port, bind) !Outcome` — take the lock for this process, writing `pid=`, `port=` and `bind=` lines. `.taken` carries the `Lock`; `.held` carries the `Holder` read back from the file. Never blocks on a holder. An error is a dir the lock file cannot be created in at all, which the caller decides about.
- `Lock.release(io)` — let the dir go and remove the file. POSIX unlinks THEN closes (closing first leaves a window in which a newcomer locks the still-linked inode, the unlink removes the path from under it, and a third process locks a fresh inode at the same path: two holders). Windows deletes after the close; a newcomer that already holds the file shares no delete, so that delete fails harmlessly.
- `Holder` — `pid`, `port`, `bindStr()`, `known()`. `pid == 0` is a dir held by a process that left no record.
- `holderOf(io, data_dir) Holder` — the record in the dir's lock file, whoever holds it.
- `ownPid()`, `pidAlive(pid)` — this process's id, and whether a pid still names a running process (any process: the question is whether the record's writer is gone).

## Dependencies

- `std`, `builtin` — no other repo modules at run time
- `kernel32` — `CreateFileW`, `ReadFile`, `WriteFile`, `DeleteFileW`, `OpenProcess`, `GetExitCodeProcess`, `Sleep`, declared locally in the house pattern; std supplies `CloseHandle`, `GetLastError`, `GetCurrentProcessId` and the WTF-8 to WTF-16 path conversion
- `worker/bounded.zig` — tests only, to run the second-process probe with a bound

## Usage Context

`src/main.zig` takes it once, in `claimDataDir`, right after the console relaunch and before anything else touches the data dir: after every CLI verb and smoke has returned, so a thin verb never pays for it, and after `detachOwnConsole`, so the parent never holds the lock its windowless child is about to take. The verdict decides the start:

- nobody holds the dir: serve, and hold the lock until exit (released by hand on the app-mode `exit()` path, which runs no defer);
- another veil holds it and this is a server-only start: refuse with one log line naming the holder's pid, bind and port, exit code 75 (sysexits' EX_TEMPFAIL: a service manager that retries succeeds once the holder is gone);
- another veil holds it and this is a desk start: open the desk as a client of that server and exit when the window closes. That server is not ours to stop; nothing bound a port or wrote the dir. The desk is handed the holder's port from the record (desk `AttachTarget`) and pinned to it on the loopback for the run, so a settings.json naming another server cannot point it elsewhere; a record with no port pins nothing;
- the lock file cannot be created at all: serve unguarded and say so.

Registered directly in `src/tests.zig`.

## Notable Implementation Details

- The sharing violation on Windows is reported before any truncation: a refused `CREATE_ALWAYS` changes nothing on disk. On POSIX the file is created without truncation and only cut to the new record once the flock is ours.
- A held dir with no live veil on record is looked at again, ten times 50 ms apart, before it is reported held: a holder may be between its open and its write, or an unrelated process (a sync client, a scanner) may be reading the file at that moment. A live pid on record ends the wait at once.
- The record is three `key=value` lines, parsed leniently: CRLF, a partial write and garbage all read as an unknown or partial holder, and the gate never depends on the record.
- Lock handles are not inherited: `CreateFileW` with null security attributes, and std's `O_CLOEXEC` on POSIX, so a worker subprocess cannot keep a dead server's lock alive.
- Tests: a second take in the same process is refused with the holder's record (a second open is what a second process is to the lock, on both OSes); a stale file with a dead pid is taken and overwritten; the record parser is pinned; and two tests run a REAL second process through the house shell pattern. A probe (PowerShell's `File.Open` for write access sharing everything, so only the holder's share mode can refuse it; `flock -n` on POSIX) is refused while this process holds the dir and succeeds once it lets go. A holder in another process, writing its own pid and port 4242, is reported with exactly those, and the dir is free again once it exits. The POSIX halves skip where `flock(1)` is absent (macOS). Counterfactual, measured 2026-10-15: a holder that shares write turns the in-process, second-process and main.zig claim tests red.
- Not handled: Windows paths past 260 characters (no `\\?\` prefix), and a data dir on a filesystem without lock support (POSIX `error.FileLocksUnsupported` surfaces as the unguarded verdict).

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
