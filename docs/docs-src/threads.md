# threads

**File:** `src/threads.zig`  
**Module:** `root`  
**Description:** The one way the server starts a thread. `vthread.spawn("role", f, args)` is `std.Thread.spawn` with a small committed stack on Windows and a thread name.

---

## Purpose Summary

Zig 0.16's `std.Thread.spawn` on Windows passes its `stack_size` (16 MiB by default) to `NtCreateThreadEx` as the stack **commit**, not the reserve. Every thread charged its whole 16 MiB to the machine's commit limit the moment it started, used or not.

On 2026-10-11 the live app sat at 4.7 GB of commit with 160 threads before its first request. Its 148 default-config stacks held 2.37 GB of that. httpz's per-worker body buffers held most of the rest (see `main.zig`). On a machine already near its commit limit, that pushed Windows to 91% of it.

`spawn_config` commits 256 KiB on Windows and leaves `StackReserve` at the executable header's default of 16 MiB. A thread can still grow to the same depth. Pages commit one at a time as the guard page is touched, exactly as the main thread's stack always has: its header commit is 4 KiB. LLVM emits `__chkstk` probes for every Windows frame over a page, so a large frame walks the guard page in order. A test recurses 8 MiB deep on a 256 KiB-commit thread.

POSIX keeps the std default. A stack there is a fixed mapping that cannot grow past its size, so shrinking it would shrink the real depth. Its pages take RAM only when touched. Linux does count the writable mapping in `Committed_AS`, which binds only under strict overcommit (`vm.overcommit_memory = 2`).

Each thread is named `veil:<role>` with `SetThreadDescription`, so a debugger, Process Explorer and the vitals sampler can tell which role owns which thread.

## Key Exports

- `spawn(comptime role, comptime f, args)`: same errors, return value and argument tuple as `std.Thread.spawn`
- `spawn_config`: the config every thread uses
- `io_stack_size`: the stack size to give `std.Io.Threaded.init`, whose pool threads go through the same spawn
- `nameCurrent(comptime name)`: name the calling thread, Windows only, best effort

## Usage Context

Every thread in `src/` starts here. The desk carries a body-identical twin in `desk/src/threads.zig`, and vendored httpz carries the same config in `vendor/httpz/src/spawn_cfg.zig`. `check.ps1 -Scan` and `check.sh --scan` flag any `Thread.spawn(.{}, …)` left anywhere, and compare the two twins below their headers.
