# main

**File:** `src/main.zig`  
**Module:** `root`  
**Description:** Entry point and wiring. Dispatches the worker entry and the CLI verbs, then — for anything else — resolves the install paths, brings up auth, the vault and the supervisor, registers the route table, and either blocks in the HTTP listener or hands the main thread to the desktop GUI.

---

## Purpose Summary

`main.zig` is the one place that knows what invoking this binary means. The same executable is the server, the desktop app, a swarm worker, and the `veil` command line, so the first job of `main()` is to read argv and decide which of those is being asked for. Only after every short-circuit has failed to fire does it boot the server.

There is no `init_subsystems()` and no injected context struct. Subsystems are constructed as locals on `main`'s stack in dependency order — `Auth`, the neuron bridge, the ledger, API keys, the supervisor, the audit log, the login guard, the key vault, the server config — and then gathered into one `App` value that every handler receives. `App` lives on that stack for the life of the process, which is sound precisely because `main` does not return in normal operation: it blocks in `listen()`, or it blocks in the GUI loop and then calls `std.process.exit`.

## Public surface

- `main(init: std.process.Init) !void` — the entry point
- `HAS_GUI` — whether the desktop GUI was compiled in (`build_options.gui`, from `-Dapp`, default true)
- `std_options` — pinned to `.log_level = .info`, because the `ReleaseFast` default of `.err` would silently swallow every operational message, including the one that prints a generated admin password

Everything else in the file is private: the route handlers (`health`, `fleet`, the four static asset handlers), the boot helpers, and the Win32 lifecycle shims.

## What `main` does, in order

1. **Argv triage.** `worker` runs the swarm worker entry (this is how the supervisor spawns a mind). `browser-smoke`, `local-host` and the `*-smoke` verbs short-circuit to their own entry points because they need the real threaded io and process environ, not the thin CLI client. `--desk` arms desktop mode; `--server-only` (alias `--headless`) disarms it.
2. **Paths.** The install root is the executable's directory — or the repository root, when the exe is sitting in `zig-out/bin`. `data/` hangs off it unless `NEURON_LOOPS_DATA` says otherwise. The port is resolved once here, `NL_PORT` else `8787`, and shared with the CLI client so the two can never disagree.
3. **CLI dispatch.** If the first argument is a verb `cli.isCommand` recognizes, the command-line client runs and the process exits with its code. No server is booted in-process; a verb that needs one talks to it over HTTP.
4. **Console detach (Windows, app mode).** If this process is the *only* one attached to its console — the Explorer double-click case — it relaunches itself windowless and exits. Started from a shell, a shell is attached too, the guard sees the higher count, and nothing happens, so a developer keeps their terminal and their output.
5. **Ollama tuning.** If a local Ollama is actually answering, sane defaults for parallelism and context length are persisted for its next start. It deliberately does not kill a running Ollama, since a bare `ollama serve` has no tray to relaunch it.
6. **Auth, the admin password, and the bind.** Covered below.
7. **The rest of the wiring.** Supervisor re-adoption of swarms left running by a previous process, retention pruning, the rate limiter, the audit log, the vault, the admin-owned server config, then `App`.
8. **Background threads.** `Supervisor.bgLoop` (swarm reconcile and retention GC — off the request threads, because a reconcile can spawn a worker process and would otherwise starve the pool) and `sched.bgLoop` (due scheduled tasks, each of which fires a full chat turn).
9. **The route table.** Static assets at `/`, `/app.js`, `/styles.css`, `/models.json`, then every `/api/v1/*` route. See [gateway/http](gateway/http.md) for the shape of a handler.
10. **The banner**, then `listen()` — or app mode.

## The bind, and the password that follows from it

The server binds **every interface by default**. `NL_BIND=127.0.0.1` (or `localhost`) is the opt-in that keeps it on this machine; anything else, including the unset case, listens on `0.0.0.0`. The startup banner reports which one actually happened, enumerating the machine's real addresses so somebody can type one.

The admin password follows from that. `NL_ADMIN_PASSWORD` always wins. Otherwise, on a reachable bind, a password is generated — and then made true before it is written: seeding only ever *creates* an account, so the code proves the password logs in, rotates it if it does not, and only then saves it to `data/admin-password.txt`. It reads that file back on the next boot rather than minting a fresh secret, because a rotating password that the recorded file no longer matches is reassuring and wrong. On a loopback bind with nothing set, no password is generated and the shipped default stands.

The full operator walkthrough is on [running a server](guide/server.md).

## Server mode and app mode

`--server-only`, or a `-Dapp=false` build, ends in `server.listen()`, which blocks until the process is stopped.

Otherwise the two swap places: raylib's window creation and event pump are main-thread-only, so the GUI takes the main thread and `httpz` gets a background one. The desk is not a child process any more — `desk.runApp()` **returning** is the shutdown signal that a watcher thread used to derive from a child exit. On Windows the process first joins a kill-on-close job object, so workers, the neuron binary and the browser host are reaped even after a hard kill where no `defer` runs.

If the HTTP thread cannot be spawned at all, it falls back to a blocking `listen()` on this thread rather than opening a window onto no backend.

## Failure behaviour

Not uniform, and deliberately so. Warm-up steps that can degrade — the auth and API-key warms, the desktop key preload, the legacy memory migration, Ollama tuning, the job object — log and carry on. A failure that would leave a half-built server, such as path resolution or `httpz` init, propagates out of `main` as an error. In app mode a listener that cannot bind (usually another `veil` already holding the port) logs loudly and leaves the window open but backendless, because a mysteriously disconnected GUI is a worse outcome than a stated one.

## Dependencies

- `auth/`, `config/`, `admin/`, `obs/`, `plan/` — the subsystems it constructs
- `gateway/http` — `App`, which it fills and hands to every route
- `worker/` — the supervisor, deploy, fanout, control writer, chat service and tools, scheduler, metrics, rate limiter
- `cli.zig` — the verb table and dispatcher
- `desk` — imported only when the GUI is compiled in (a comptime branch keeps it out of the server-only graph entirely)
- `httpz`, `build_options`

## Usage Context

Invoked directly by a person, by a service manager, by the supervisor (as `worker`), or by the CLI's own auto-start. One binary; what it becomes is decided in the first thirty lines of `main`.
