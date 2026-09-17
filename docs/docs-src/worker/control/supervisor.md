# supervisor

**File:** `src/worker/control/supervisor.zig`  
**Module:** `worker/control`  
**Description:** The swarm supervisor: spawns each cast as its own detached OS process, tracks the live fleet, and re-adopts running swarms when the server restarts. A cast survives the server that started it.

---

## Purpose Summary

The supervisor is the control plane's process manager. A cast/deploy is launched as a separate worker process (not a thread), so a running hive outlives the server that spawned it and a server restart re-adopts the swarms already on disk rather than orphaning them. It owns the mapping from swarm id to process, the run directory each swarm writes into, and the fleet view the API and CLI read.

## Key surfaces

- Spawn a detached worker for a cast and record it in the registry.
- Relaunch a crashed worker (a dead `worker.pid`, no `DONE`) into the same run dir, up to `MAX_RESTARTS` times; the count starts over once `HEALTH_RESET_SECS` pass after a restart. A relaunch that cannot launch opens the circuit breaker, so the entry is left crashed rather than awaiting a relaunch that never comes. `relaunchPending(run_dir)` tells a caller that just read a dead pid whether a relaunch is coming, mirroring `shouldRestart` through one pure `restartPolicy` and reconcile's own probe. It vouches only from a probe or relaunch within `RELAUNCH_TRUST_SECS`, so a wedged loop can't keep a dead run open. The chat engine's hive waits ask it (`swarmTerminal`).
- Re-adopt swarms found in the data dir on boot (the "N swarms re-adopted" line at startup). Every run dir gets its own entry, skipped only when an entry already tracks that very dir. The key is the name clients reach the dir by: a scheduled run's conversation id (`scheduled_{task}_{stamp}`, never the stamp every task that ran that minute shares), else the dir's basename. When another dir already holds that key (two accounts can mint one conversation id), the later dir's key gets its account appended (`{name}.u{uid}`).
- Resolve a swarm from any id a caller holds (`resolve(uid, id)`). A key that names no dir of its own (a spawn-time hex id, an account-qualified key) names exactly its swarm, and the caller checks the owner. A chat or deploy dir's basename, or a conversation id, names one of the CALLER's run dirs: the conversation's build root, a sub-chat's being its primary's, a scheduled run's being `_sched/{task}/runs/{stamp}`. Re-casts leave several entries on one dir, and the newest wins.
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
