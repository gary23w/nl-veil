# threads

**File:** `desk/src/threads.zig`  
**Module:** `desk`  
**Description:** The desk package's copy of the server's thread helper: `vthread.spawn("role", f, args)` commits 256 KiB of stack on Windows instead of 16 MiB and names the thread `veil:<role>`.

---

## Purpose Summary

The desk is a module of its own inside `veil` and cannot import `src/threads.zig`, so it carries the same body below its own `//!` header. See that case file (`threads`) for why: on Windows, Zig 0.16's `std.Thread.spawn` commits its whole `stack_size` up front.

## Dependencies

- `std`, `builtin` — nothing else from the desk package
- TWIN: `src/threads.zig` — the server package's copy; `scripts/check.ps1 -Scan` and `check.sh --scan` compare the bodies under `[twins]`

## Usage Context

- `main.zig` — the poller and chat threads, and the desk's three `std.Io.Threaded` pools (the window's, the chat's and the crash reporter's) via `io_stack_size`
- `gitvc.zig` — the lease that keeps a push's credentials file young while git runs; the test-only GitHub/git stand-in
- `llm.zig` — the test-only model stand-in; a test's curl watchdog
- `updater.zig`, `watchdog.zig` — the update worker and the UI-hang watchdog
- Not through it: the whole-file twins `bounded.zig` (its watchdog's `guard_spawn`) and `wsock.zig` (tests, explicit 1 MiB)
