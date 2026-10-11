# threads (desk)

**File:** `desk/src/threads.zig`  
**Module:** `desk`  
**Description:** The desk's twin of `src/threads.zig`: every desk thread starts through `vthread.spawn("role", f, args)`, with a 256 KiB stack commit on Windows and a `veil:<role>` name.

---

## Purpose Summary

The desk is its own Zig module and cannot import the server's file, so it carries a copy whose body must match below the `//!` header. The scan checks that. The reason for the file is the same: Zig 0.16 commits a thread's whole 16 MiB default stack on Windows, and the desk's poller, chat worker, watchdog, updater and git keeper each paid it. The desk's `std.Io.Threaded` pools get `io_stack_size` for the same reason.

See [threads](../threads.md) for the measurements and the design.
