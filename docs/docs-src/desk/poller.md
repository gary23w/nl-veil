# poller

**File:** `desk/src/poller.zig`  
**Module:** `desk`  
**Description:** The veil-desk background worker thread — the only thread permitted to touch std.Io — which polls the server and filesystem ~1Hz, drains UI commands, and publishes all state into the mutex-guarded Store the raylib UI reads at 60fps.

---

## Purpose Summary

Owns the single std.Io handle and performs every IO the desktop app does: probes server liveness + fleet counters, scans the data dir for swarms, tails the selected swarm's events.jsonl / files / config, executes control writes and deploy/delete, flushes the in-memory log to disk, and raises notifications on state transitions. It runs on its own thread at roughly 1Hz and pushes results into a lock-guarded Store; the UI thread only calls raylib and reads that Store, never blocking on IO. This is the thread-boundary enforcement point: UI never calls io, poller never calls raylib.

## Key Exports

- `Poller` (struct) — holds io/gpa/store, an atomic `stop` flag, poller-local transition memory + notification de-dup state, an events.jsonl re-read cache, and all fixed-size scratch buffers (swarm/event/file/file-content/config)
- `Poller.run` — the only pub method; the thread entry point. Loops until `stop` (monotonic) is set: each pass calls `drainCommands` then `refresh`, then sleeps 10x100ms polling the stop flag, breaking early via `hasPendingCmd` so queued UI commands are serviced within ~100ms instead of a full second
- `refresh` (internal) — one poll tick: throttled fleet GET (every ~5s), roster scan, selected-swarm event tail + config + files read, publish-under-lock, then notifyTransitions
- `drainCommands` (internal) — pops the Store command ring and dispatches select/say/set_goal/stop/deploy/delete/open_folder/open_file
- `doControl`/`doDeploy`/`doDelete` (internal) — write a control JSON via scan.writeControl, POST a UI-built DeployReq body via netcli.deploy, and delete a swarm (API DELETE for server swarms, single-dir deleteTree for flat CLI runs)
- `notifyTransitions` (internal) — emits notifications on server up/down, swarm-finished (live→stopped, de-duped), and the zero-gradient RSI sentinel on the open swarm

## Dependencies

- store.zig (Store: the mutex-guarded shared state, command ring popCmd/cmd_head/cmd_tail, pushNotif, settings incl. token/token_manual/dataDir/port)
- scan.zig (filesystem layer: listSwarms, tailEvents, readSwarmConfig, listWorkFiles, readWorkFile, writeControl; types SwarmSummary/Ev/Metrics/FileRow/SwarmConfig and MAX_SWARMS/MAX_LOG/MAX_FILES caps)
- netcli.zig (HTTP client: fleet GET, deploy POST, delete DELETE against the local server port)
- log.zig (in-process ring: trace/dbg/info/err, drain, setClock, levelTag)
- std.Io (all IO: Dir.cwd read/write/stat/deleteTree, Timestamp, sleep, process.spawn) and builtin (per-OS open-folder argv)

## Usage Context

Instantiated by the desktop app's main and launched on a dedicated background thread (its `run` is the thread body). Runs for the whole app lifetime; the raylib UI thread signals shutdown by setting the atomic `stop` flag. All user actions in the UI (deploy form, say/set-goal/stop buttons, selecting a swarm or file, delete, open-folder) are enqueued as commands into the Store and executed here on the next drain; all dashboard/detail data the UI renders originates from this thread's `refresh` writes into the Store.

## Notable Implementation Details

Concurrency: one io-owning thread + a Store mutex is the entire model. Everything shared (fleet counters, roster, events, files, notifications) is copied into the Store under store.lock()/unlock(); transition memory, notification de-dup, and the event cache are poller-local so they need no lock; `stop` is atomic/monotonic. Fleet throttle + flap debounce: filesystem reads happen every ~1s but the server-hitting GET /fleet runs only every FLEET_EVERY_S=5s (last_fleet_s); a `miss_streak` requires OFFLINE_AFTER=2 consecutive misses (~10s) before flipping the dashboard offline, and within the grace window it holds last-known online + counters rather than zeroing them. Key perf comment: a separate raw serverOnline() TCP probe was DELETED because opening+closing a socket without sending a request left the server in CLOSE_WAIT with worker threads spinning on dead sockets, pinning ~7 cores; liveness now derives from the real fleet request (Connection: close). Event re-read cache: statFile size of <data>/<sel>/events.jsonl is compared against ev_cache_size for the same selection; if unchanged and non-zero it reuses the already-parsed ev_scratch ring + Metrics, skipping the up-to-8MB read + two-pass parse every tick (this is what stops it pegging a core during a cast). Fixed buffers/gotchas: fc_scratch is 16KB (1<<14) for the open file; swarm/event/file scratch are sized by scan.MAX_* caps; `jstr` returns a slice into a MODULE-GLOBAL static `jstr_buf` [32]u8 (truncates version to 32 chars, non-reentrant — safe only because this single thread consumes it immediately); `jint` parses digits only (no sign/overflow guard). JSON for control ops is hand-built with manual escaping (appendEsc: escapes \"/\\/\\n, drops \\r, tab→space). Two distinct control planes: interactive control (say/set_goal/stop) goes through a FILESYSTEM control write (scan.writeControl into the run dir), while deploy/delete/fleet use HTTP netcli; deploy posts the UI-built body verbatim and only guards against an empty body. doDelete is deliberately surgical — server swarms (rel contains '/') go through DELETE /api/v1/swarms/<hexid> so the worker is stopped+removed, flat CLI runs deleteTree exactly their own dir, never a sweep. syncDesktopKey re-reads <data>/.desktop_key every poll and adopts a rotated token unless the user manually saved one (token_manual), fixing stale-token deploy/delete rejections. flushLog drains up to 128 log lines, formats HH:MM:SS+level, appends into log_buf, halves log_buf when it exceeds 512KB, and rewrites the WHOLE veil-desk.log file each flush (writeFile, not append) — so the on-disk log holds only the bounded in-memory tail, not full history. neuron-db seam: events.jsonl is the capture-fidelity event stream and scan.Metrics.gradient_warn is the shipped zero-gradient RSI sentinel surfaced as a notification for the open swarm.

---

*Case file grounded in the module's `//!` header and public API.*
