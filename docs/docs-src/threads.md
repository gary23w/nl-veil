# threads

**File:** `src/threads.zig`  
**Module:** `main`  
**Description:** How the server starts a thread: `vthread.spawn("role", f, args)`, which commits 256 KiB of stack on Windows instead of 16 MiB and names the thread `veil:<role>`.

---

## Purpose Summary

On Windows, Zig 0.16's `std.Thread.spawn` hands its `stack_size` (16 MiB by default) to `NtCreateThreadEx` as the stack commit, not the reserve. Every default-config thread charged its whole 16 MiB to the machine's commit limit the moment it started, whether or not it ever touched it, so a veil with ~150 threads held gigabytes of commit while its working set stayed small.

`spawn` commits `windows_stack_commit` (256 KiB) instead. The reserve is still the executable header's 16 MiB, so a thread can grow exactly as deep as before: the rest of the stack commits page by page as the guard page is touched, the way the main thread's stack always has. POSIX keeps the std default, because a POSIX thread stack is a fixed mapping that cannot grow past its size.

## Key Exports

- `spawn(comptime role, comptime f, args)` — `std.Thread.spawn` with `spawn_config`; the new thread names itself `veil:<role>` before it calls `f`. Same errors, same return value, same args tuple
- `spawn_config` — `stack_size` = `windows_stack_commit` on Windows, `std.Thread.SpawnConfig.default_stack_size` elsewhere
- `io_stack_size` — the same size, for `std.Io.Threaded.init(.., .{ .stack_size = vthread.io_stack_size })`: that pool's threads go through `std.Thread.spawn` too
- `windows_stack_commit` — 256 KiB
- `nameCurrent(comptime name)` — `SetThreadDescription` on the calling thread; Windows only, best effort

## Dependencies

- `std`, `builtin` — nothing else, so `desk/src/threads.zig` can carry the same body (the desk is a module of its own and cannot import this file; `scripts/check.ps1 -Scan` and `check.sh --scan` compare the two below the `//!` header under `[twins]`)
- `kernel32` — `SetThreadDescription`, `GetCurrentThread`

## Usage Context

- `main.zig` — the supervisor, sched, tots and server threads, the app-port probe, and the server's `std.Io.Threaded` pool (`io_stack_size`)
- `config/cf_tunnel.zig`, `config/cf_r2.zig` — the tunnel's boot, switch and child-wait threads; the R2 sync thread
- `cli/swarm_tui.zig` — the key reader
- `worker/chat/engine.zig` — every chat turn and its pulse
- `worker/run.zig`, `worker/mcp/client.zig`, `worker/llamaeng.zig`, `worker/modelpull.zig`, `worker/builtin_endpoint.zig`, `worker/browser/broker.zig` — watchdogs, the built-in engine's unloader and listener, model pull/import/check, the browser broker
- Tests across `src/` spawn through it too
- Not through it, with the same rule spelled out: vendored httpz (`vendor/httpz/src/spawn_cfg.zig`, which also names the request-pool threads `veil:http`), and the whole-file twins `worker/bounded.zig` (its watchdog's `guard_spawn`) and `worker/wsock.zig` (tests, explicit 1 MiB)
- `scripts/check.ps1 -Scan` (`[threads]`) and `check.sh --scan` flag any `Thread.spawn(.{}` left in `src/`, `desk/src/` or `vendor/httpz/src/`

## Tests

- `spawn` runs the function with its args and joins
- a thread that committed 256 KiB still recurses through 8 MiB of 16 KiB frames (the guard page grows it on demand)
- `spawn_config` is small on Windows and the std default elsewhere, and equals `io_stack_size`
