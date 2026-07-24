# host

**File:** `src/worker/browser/host.zig`  
**Module:** `worker/browser`  
**Description:** Local-host daemon plus its client side — a per-machine background `veil local-host` process that owns the stateful local resources behind the loopback broker, so every subprocess-per-call client shares one browser session.

---

## Purpose Summary

In the client-driver round-2 design, browser/pixel/mcp tools run on the client by default, delegated from the server — but the desk runs each delegated tool as a fresh `veil exec-tool` subprocess, so a process-global browser session cannot survive between navigate and read. This daemon is the fix: `runDaemon()` starts the broker, publishes `{port,token,pid}` to a discovery file, and idle-exits; `ensure()`/`forward()` on the client side read that file, lazily spawn the daemon if absent or dead, and forward browser commands to it over loopback. No desk changes are needed.

## Key Exports

- `Info` — `{ port, token }` for a discovered/started daemon.
- `runDaemon(gpa, io, env)` — the `veil local-host` entry: bring up the broker, write the discovery file, watch-loop, idle-exit. Blocks.
- `ensure(gpa, io, env) ?Info` — return a reachable daemon, spawning one and waiting (up to 12 s) if needed; null if it could not be started.
- `forward(gpa, io, env, key, action, params_json) []u8` — forward one browser action to the daemon (starting it if needed); returns its JSON response (gpa-owned) or a JSON error.

## Dependencies

- `broker.zig` — the daemon's actual listener.
- `manager.zig` — `sweepIdle`/`lastActivity`/`closeAll` drive the idle-exit decision and teardown.
- `util.zig` — raw-thread-safe `sleepMs` in the wait/watch loops.
- `../httpc.zig` — the client side's loopback POSTs (`ping` reachability probe; `forward` with a 180 s timeout and 48 MiB response cap).

## Usage Context

`src/main.zig` routes the `veil local-host` subcommand to `runDaemon`. `worker/tools.zig` and `worker/pixelrag.zig` import it for the client-delegated (`roam`) path, where `exec-tool` subprocesses call `forward`.

## Notable Implementation Details

- The discovery file lives on local temp (`{TEMP}/nl-veil-localhost.json`), never OneDrive — sync would lock or delay it.
- Idle-exit: the watch loop *sweeps* idle sessions (`manager.sweepIdle`) rather than just counting them — an abandoned session used to hold the live count above 0 forever, so the daemon (and its headless browsers) never idle-exited once anything had opened a session. It exits after 5 minutes (`IDLE_EXIT_S = 300`) with no live sessions and no recent activity, closing all sessions and deleting the discovery file.
- Reachability is a real round-trip: a `ping` action POSTed with the token, expecting `pong` in the reply — a stale file with a dead pid fails this and triggers a respawn.
- Windows: the daemon is spawned from a temp *copy* of the exe (`{TEMP}/nl-veil-localhost.exe`), not the install path — a daemon holding the install exe open forced every rebuild/restart script to kill it, which is exactly how the shared browser died on every restart. Any copy trouble falls back to the install exe. POSIX does not lock running binaries, so no copy there.

---

*Case file grounded in the module's `//!` header and public API.*
