# supervisor

**File:** `src/worker/control/supervisor.zig`  
**Module:** `worker/control`  
**Description:** The swarm supervisor: spawns each cast as its own detached OS process, tracks the live fleet, and re-adopts running swarms when the server restarts. A cast survives the server that started it.

---

## Purpose Summary

The supervisor is the control plane's process manager. A cast/deploy is launched as a separate worker process (not a thread), so a running hive outlives the server that spawned it and a server restart re-adopts the swarms already on disk rather than orphaning them. It owns the mapping from swarm id to process, the run directory each swarm writes into, and the fleet view the API and CLI read.

## Key surfaces

- Spawn a detached worker for a cast and record it in the registry.
- Re-adopt swarms found in the data dir on boot (the "N swarms re-adopted" line at startup).
- Report the live fleet (`/api/v1/fleet`, `/api/v1/swarms`).
- A raw-thread sleep helper (`threadSleepMs`, Win32 `Sleep` on Windows) for the waits on threads the Io runtime did not spawn: `bgLoop`'s cadence and `remove`'s rmTree retries on an httpz worker. Not `io.sleep`: on Windows that parks the thread on the runtime's per-thread alert, and a stray alert there is undefined behaviour in the ReleaseFast build.

## Dependencies

- `worker/run` — the worker entry point each spawned process runs
- `worker/control/fanout` — the events surface for a running swarm
- `gateway/http` — the App context the routes share

## Usage Context

Sits behind the deploy routes (`worker/deploy/service.zig`) and the control routes (`worker/control/writer.zig`). Every `veil cast` / `veil deploy` ultimately asks the supervisor to detach a worker; `veil list` / `veil stop` / `veil rm` read and steer the fleet it tracks.

---

*Case file grounded in the module's `//!` header and public API.*
