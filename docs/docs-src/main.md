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

In v1.1.3, `--build-version` reports the executable's own release version without connecting to a server.
The merged app also configures the desktop updater with that version and the original arguments.
Its private `--veil-apply-update` helper entry returns before server/GUI initialization; the helper waits
for shutdown, installs verified components and restarts. Windows app jobs allow explicit breakaway for
that helper while ordinary children remain subject to kill-on-close cleanup.

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

The admin password is independent of the bind address: a tunnel or another proxy can expose a loopback listener. `NL_ADMIN_PASSWORD` always wins and is applied to an existing account when it changes. Otherwise a new admin receives a generated password in `data/admin-password.txt`; an existing custom password remains in force, while the published legacy `changeme` password is rotated before listening. The generated password is saved before changing the account, then verified before listening. On later boots the file is used only if it already matches the current admin account, so a superseded password cannot return or transfer to another admin address.

The full operator walkthrough is on [running a server](guide/server.md).

## Server mode and app mode

`--server-only`, or a `-Dapp=false` build, ends in `server.listen()`, which blocks until the process is stopped.

Otherwise the two swap places: raylib's window creation and event pump are main-thread-only, so the GUI takes the main thread and `httpz` gets a background one. The desk is not a child process any more — `desk.runApp()` **returning** is the shutdown signal that a watcher thread used to derive from a child exit. On Windows the process first joins a kill-on-close job object, so workers, the neuron binary and the browser host are reaped even after a hard kill where no `defer` runs. On that return, the Cloudflare tunnel's connector is stopped first (`cf_tunnel.shutdown`), then the listener, then the process exits. On macOS and Linux nothing else stops the connector at exit. Server mode's `defer` makes the same call when `listen()` returns.

If the HTTP thread cannot be spawned at all, it falls back to a blocking `listen()` on this thread rather than opening a window onto no backend.

**The app's port is chosen before anything reads it.** Right after the data-dir claim, app mode asks `pickAppPort` for its port: the configured one (`NL_PORT`, else 8787) when it is free or comes free within `APP_PORT_SETTLE_MS` (4 s, long enough for a veil that is quitting to let go of it), else the first free port of the next `APP_PORT_SPAN` (20). Each look is made by `portFree`, a throwaway one-thread `httpz` server on the address the real one will use, so the answer carries the same socket options. The listener, the Cloudflare OAuth redirect, the browser-extension relay and the tunnel all read the chosen port, the lock record is rewritten to it (`Lock.rewrite`, for an attaching desk), and the desk is pinned to it for the run (`AttachTarget`). The OAuth client registers one redirect, on the configured port, so a veil that moved sets `cf_oauth_blocked` and its login says why rather than ending on Cloudflare's error page. Measured 2026-10-16: a v1.1.20 bundle started beside another install's veil never got a server, and its window sat on "checking the server..." for good. A server-only start keeps the configured port and fails plainly when it is taken.

Neither path is reached on a data dir another veil already serves. The data-dir claim ([config/datalock](config/datalock.md)) runs right after the console detach: a server-only start on a held dir is refused with exit code 75, and a desk start opens `desk.runApp` as that server's client, handed the holder's port from the lock record and pinned to it on the loopback for the run (desk `AttachTarget`), so the desk's own settings.json cannot point it at a server that is not the one holding its data. The process exits when the window closes; the holder keeps running.

## Failure behaviour

Not uniform, and deliberately so. Warm-up steps that can degrade — the auth and API-key warms, the desktop key preload, the legacy memory migration, Ollama tuning, the job object — log and carry on. A failure that would leave a half-built server, such as path resolution or `httpz` init, propagates out of `main` as an error. In app mode the port is picked free first (above), so a listener that still cannot bind means another program took the port in between: it logs, shows a Windows message box saying so (a double-clicked veil has no console), and leaves the window open but backendless, because a mysteriously disconnected GUI is a worse outcome than a stated one. With `--server-only` the listen error returns out of `main` and the process exits.

On Windows that failure depends on a local patch in `vendor/httpz`: the listener binds with `SO_EXCLUSIVEADDRUSE` where upstream sets `SO_REUSEADDR`. On Windows `SO_REUSEADDR` let a second `veil` bind the port the first one held, so it came up without an error while the first kept answering. The second bind now fails with `AddressInUse`, or with `AccessDenied` when one server holds `0.0.0.0` and the other asks for `127.0.0.1`. A test at the bottom of `main.zig` checks both halves: a second listen on a held port fails, and a stopped server's port binds again at once.

## Dependencies

- `auth/`, `config/`, `admin/`, `obs/`, `plan/` — the subsystems it constructs
- `gateway/http` — `App`, which it fills and hands to every route
- `worker/` — the supervisor, deploy, fanout, control writer, chat service and tools, scheduler, metrics, rate limiter
- `cli.zig` — the verb table and dispatcher
- `desk` — imported only when the GUI is compiled in (a comptime branch keeps it out of the server-only graph entirely)
- `httpz`, `build_options`

## Usage Context

Invoked directly by a person, by a service manager, by the supervisor (as `worker`), or by the CLI's own auto-start. One binary; what it becomes is decided in the first thirty lines of `main`.
