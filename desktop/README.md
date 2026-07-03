# veil-desk

The native desktop dashboard for **nl-veil** — a same-machine companion that gives you a styled UI over
every swarm on your box: deploy, monitor, chat, and stop hives; watch the live event console and metrics;
and reach the fleet **Hub**. Built in Zig + [raylib](https://www.raylib.com/), themed in the same Tokyo
Night palette as the web UI, and cross-platform (Windows / Linux / macOS).

## What it does

- **Dashboard** — server-online status, fleet counters (live swarms / minds / headroom), a one-line
  **Deploy** box, and a live roster of every swarm under your `data/` dir.
- **Swarm** — open any swarm to get the live **event console** (narrated, color-coded by kind), a
  **metrics strip** (score, pct, round, tokens, smoke gate, zero-gradient sentinel), a **chat** row that
  messages the hive (`say`), plus **Set goal** and **Stop**.
- **Hub** — the fleet hub (`hub.py`) commands for meshing many hosts into one console.
- **Settings** — data directory, server port + reachability, an API token for Deploy, notification toggle.
- **System tray + notifications** — on Windows it sits in the tray and raises native toasts on state
  changes (server up/down, a swarm finishing, a zero-gradient warning on the open swarm). In-app toasts
  always show as the cross-platform fallback.

## Architecture

Two threads, one hard rule each. The **UI thread** owns raylib (its hard single-thread requirement) and
only ever reads a mutex-guarded `Store`. The **poller thread** owns the `std.Io` handle and does *all* I/O
— it reads the run directories directly (no HTTP, no auth, no latency), TCP-probes the server for the
online signal, and only reaches the HTTP API for the two actions that genuinely need the running server
(fleet counters + deploy). Everything else — monitor, chat, set-goal, stop — flows through the same
`control.jsonl` file bus the worker already drains.

| file | role |
|------|------|
| `src/main.zig` | window, tabs, all drawing + input, tray pump |
| `src/theme.zig` | Tokyo Night palette + immediate-mode widgets |
| `src/scan.zig` | filesystem data layer (run dirs, events.jsonl, control bus, TCP probe) |
| `src/store.zig` | the mutex-guarded shared state + command/notification rings |
| `src/netcli.zig` | tiny HTTP/1.1 client (fleet GET, deploy POST) |
| `src/poller.zig` | the background worker thread |
| `src/tray.zig` | native tray + toasts (Windows), graceful stubs elsewhere |

## Build & run

Requires Zig 0.16. raylib's native system libraries must be present for the link step, so **build on the
target OS** (the normal raylib workflow):

- **Linux**: install the dev libs first — `sudo apt install libgl1-mesa-dev libx11-dev libxrandr-dev
  libxinerama-dev libxi-dev libxcursor-dev` (or your distro's equivalents).
- **macOS**: the system frameworks ship with the OS; no extra install.
- **Windows**: no extra install (uses the bundled opengl32/gdi32/winmm).

```sh
cd desktop
zig build            # produces zig-out/bin/veil-desk[.exe]
zig build run        # build + launch
zig test src/scan.zig   # data-layer tests (parses real run dirs under ../data)
```

The dependency (`raylib-zig`) is fetched and pinned via `build.zig.zon` — no vendoring needed.

## How it finds your swarms

On launch it probes `data`, `../data`, `../../data`, `../nl-veil/data` (first existing wins) so it Just
Works from the repo root, from `zig-out/bin`, or installed alongside the server. The current path is shown
in **Settings**. It reads whatever the server writes — start a swarm from the web UI or the Deploy box and
it appears in the roster within a second.

## Notes / next

- Login/register is intentionally deferred; Deploy uses an API token you paste in Settings (grab one from
  the web UI's API keys). Monitor/chat/stop need no auth (same machine, same user).
- The Hub tab currently shows the connect commands; embedding the live fleet roster (via
  `NL_HUB_URL`/`NL_HUB_SECRET`) is the next increment.
- POSIX native toasts (notify-send / osascript) are stubbed for v1 — the in-app toast covers all platforms.
