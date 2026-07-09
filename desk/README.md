# veil-desk

The native desktop dashboard for **nl-veil** — a same-machine companion that gives you a styled UI over
every swarm on your box: deploy, monitor, chat, and stop hives; watch the live event console and metrics;
and reach the fleet **Hub**. Built in Zig + [raylib](https://www.raylib.com/), themed in the same Tokyo
Night palette as the web UI, and cross-platform (Windows / Linux / macOS).

## What it does

- **Borderless own-chrome window** — the OS title bar is hidden; veil-desk draws its own with the **veil**
  mark, a **File** menu (New swarm / Refresh / Quit), minimize + close, drag-to-move, and a corner resize
  grip. A real system TTF (Segoe UI / SF / DejaVu) replaces raylib's default font.
- **Dashboard** — server-online status, fleet counters (live swarms / minds / headroom), a **New swarm**
  button, and a live roster of every swarm under your `data/` dir.
- **Deploy** — a full configuration form mirroring the web console: name, provider + model (cycle
  selectors), API key, minds (stepper), style, runtime, stack, mode, gateway model, living-hive and
  encrypt toggles, and the goal. Posts the exact `DeployReq` the server's `POST /api/v1/swarms` expects.
- **Swarm** — open any swarm to get inner tabs: **Console** (the live event log, color-coded by mind) and
  **Details** (score / pct / best / round / files / smoke gate / tokens in-out-cached / the zero-gradient
  sentinel). A **chat** row messages the hive (`say`), plus **Set goal** and **Stop**.
- **Hub** — the fleet hub (`hub.py`) commands for meshing many hosts into one console.
- **Settings** — data directory, server port + reachability, an API token (`nlk_…`) for Deploy, notifications.
- **System tray + notifications** — on Windows it owns a tray icon (anchored to a hidden message window)
  and raises native toasts on state changes (server up/down, a swarm finishing, a zero-gradient warning);
  double-click the tray icon to restore. In-app toasts are the cross-platform fallback.

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
| `src/tray.zig` | native tray + toasts (Windows hidden-window host), graceful stubs elsewhere |
| `src/catalog.zig` | embedded provider/model catalog + deploy option sets (mirrors models.json) |
| `assets/icon.png` | desktop app icon used for the window/taskbar icon |

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

**The server can build and host it for you.** A plain `zig build` at the repo root now does a server-only
build. Pass `-Ddesktop=true` to also build veil-desk (best-effort), and run with `zig build run
-Ddesktop=true` to start the server in desktop-host mode so the dashboard launches on startup. Set
`NL_NO_DESKTOP=1` to force-disable launch even in desktop mode. `python deploy.py desktop [--install]
[--launch]` builds it and can register a login autostart entry.

**Connects with no key pasting.** On a localhost bind the server mints an admin API key and drops it at
`<data>/.desktop_key`; the desktop reads it on launch, so **Deploy works out of the box** — no need to
create or paste an `nlk_` key. (Text fields also support Ctrl+V now if you ever do paste one.)

**Tray on Windows 11:** the icon is created successfully, but Win11 hides *new* tray icons in the overflow
flyout (the `^` chevron by the clock) by default. Click the `^` and drag veil-desk onto the taskbar, or
pin it via Settings → Personalization → Taskbar → Other system tray icons.

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
