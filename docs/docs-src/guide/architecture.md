# architecture

**Covers:** `src/main.zig`, `build.zig`, `web/public/`, `desk/src/`, `src/cli.zig`  
**Kind:** orientation — this page is about how the parts fit, not about one file  
**Description:** One server process. The web app, the native desktop, and the `veil` command line are three clients of the same `/api/v1` surface, and two of the three live in the same binary.

---

## The shape of it

There is one program. `src/main.zig` resolves the install paths, brings up auth, the key vault, the supervisor and the audit log, registers the route table, and then either blocks in `server.listen()` or — in app mode — hands the main thread to the GUI and runs the HTTP server on a background thread.

Everything a client can do, it does over HTTP:

```
                     one process, one port (NL_PORT, else 8787)
   web browser  ─┐
   native desk  ─┼──►  /api/v1/*  ──►  gateway/http.zig  ──►  handlers
   veil CLI     ─┘        ▲                (App, requireUser)      │
                          │                                       ▼
                    route table in main.zig            auth · vault · supervisor
                                                       chat engine · scheduler
```

The desk and the CLI are not privileged shortcuts into the internals. They send the same requests a browser sends, and they authenticate the same way.

## Face one — the web app

Four files under `web/public/`: `index.html`, `app.js`, `styles.css`, `models.json`. There is no bundler, no transpiler and no framework; `index.html` is a shell whose body is essentially `<div id="app"></div>`, and the whole interface renders from `app.js`. The tabs are **Dashboard, Chat, Tasks, Swarms, Admin** (admin only) and **Settings**.

They are not read off disk at runtime. `build.zig` adds each one as an anonymous import and `main.zig` pulls them in with `@embedFile`, so the four assets ship inside the binary and are served by `staticIndex` / `staticJs` / `staticCss` / `staticModels`. The practical consequence: editing the UI needs no build tooling, but it does need a rebuild of `veil`.

Cache headers on the three main assets are `no-cache, must-revalidate`, so a redeploy is picked up on reload rather than living on in a browser cache.

## Face two — the native desk

`desk/src/*.zig` is compiled **into the same binary**. `build.zig` exposes `-Dapp` (default true); when it is on, raylib is resolved as a *lazy* dependency and the desk module is imported into the exe. `-Dapp=false` produces the server-only build — no raylib, no GL, and the dependency is never fetched at all. `build_options.gui` records the outcome rather than the request, so a build that could not fetch raylib cannot claim a GUI it does not have.

There is no longer a separate `veil-desk.exe` for the server to find and spawn. `main.zig` keeps a note where that machinery used to be: the spawn path, the two-layout probe and the child-handle watcher are gone, because the window now runs on this process's main thread. `zig build desk` still exists and still builds the standalone binary, but it is a developer convenience — nothing shipped looks for its output.

App mode is worth understanding as a lifecycle: raylib owns the main thread, `httpz` gets a background thread, and `desk.runApp()` **returning** is the shutdown signal. Close the window and the server stops with it. That is why `--server-only` (alias `--headless`) exists — a headless host, a service manager, or an auto-start that brings up its own UI wants the server without a window.

On Windows, app mode also puts the process into a kill-on-close job object, so workers, the neuron binary and the browser host die with it even after a Task Manager kill where no `defer` ever runs.

## Face three — the CLI

`src/cli.zig` holds the verb table (`isCommand`) and the dispatcher, with the interactive REPL and the fleet console in `src/cli/chat.zig` and `src/cli/hub.zig`. A verb never boots the server in-process; it makes an authenticated HTTP call, auto-starting a detached daemon first if nothing is listening.

The shipped verbs are:

| verb | what it does |
|---|---|
| `cast` · `deploy` | start a swarm |
| `list` · `ls` · `ps` | the roster |
| `stop` · `rm` · `delete` | stop or remove a swarm |
| `events` · `logs` · `watch` | follow a run's event stream |
| `chat` | the interactive REPL against the server's chat brain |
| `sched` | scheduled tasks |
| `hub` | the fleet console (`hub all`, `hub goal`, `hub stopall`) |
| `doctor` · `health` | check the local server |
| `desktop` · `desk` | open the desktop app |
| `exec-tool` | run one tool through the same executor a mind uses |
| `sync-manifest` · `sync-read` | the file-sync helpers |
| `help` · `version` | the usual |

Anything that is *not* a verb falls through to booting the server, which is what makes a bare `veil` start the app.

## How local clients authenticate

The server always mints an admin API key and writes it to `{data}/.desktop_key`. The desk reads it at startup; the CLI reads it in `Ctx.loadToken` before every dispatch. It is a file readable by the OS user who started the server, and it is written unconditionally — minting it only on a loopback bind meant that turning on network access silently broke every same-machine client, which is the kind of bug that looks like the network.

## Where tools actually run

On the server, in the server's process, as the OS user who started it.

A browser cannot execute a shell command, so the web client deliberately **omits** the `tool_client` flag when it posts a message: absent, the server runs the turn's tools itself. The desk sets it when it wants to run tools on its own machine instead. Both surfaces converge on `POST /api/v1/chat/tool`, which is the same executor the hive minds use — see [tools](../worker/chat/tools.md) and [engine](../worker/chat/engine.md).

This is the single most important fact about the deployment: a chat turn is code running on the host. It is why non-admin accounts are capability-gated rather than merely path-scoped. See [accounts and the sandbox](accounts.md).

## Threads

- The HTTP server: `httpz` in its blocking worker model, a 128-thread pool, one thread per live connection.
- `Supervisor.bgLoop` — swarm reconcile and retention GC, deliberately off the request threads because a reconcile can spawn a worker process.
- `sched.bgLoop` — due scheduled tasks, each of which runs a full chat turn.
- One detached thread per chat turn, claimed and released by the engine's turn-slot table.
- In app mode, the GUI on the main thread and the listener on one more.

Keep-alive is on and bounded: idle sockets are reaped at 60s, a request is capped at 15s, and one connection serves `NL_KEEPALIVE_REQUESTS` (default 200) requests before it is recycled. The body cap is lifted to 16 MiB so a chat message carrying an image attachment is not rejected before the handler sees it.

## What it does not depend on

No database service, no Python, no Node. Durable state is files under the data directory, plus the `neuron` memory binary at `{home}/bin/neuron`, which is called as a subprocess and is **fail-open** — if it is missing, memory quietly does nothing and the rest of the system behaves as if it never existed.

---

Next: [running a server](server.md) · [accounts and the sandbox](accounts.md) · the entry point itself, [main](../main.md)
