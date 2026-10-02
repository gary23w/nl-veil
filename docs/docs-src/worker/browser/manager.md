# manager

**File:** `src/worker/browser/manager.zig`  
**Module:** `worker/browser`  
**Description:** Process-global browser-session registry — stateful sessions keyed by run_dir that survive across tool calls, with every op serialized on one mutex and returned as a gpa-owned JSON result string.

---

## Purpose Summary

A browser session must survive navigate → read → click → ..., but `tools.execute()` runs per-call with a fresh ToolCtx — so sessions live here, keyed by run_dir. run_dir is per-user on the chat surface and per-run for a cast, so a keyed session never crosses tenants or runs. A browser process is heavy (~1-2 s to launch), so sessions open lazily on first use and are reused; the registry caps live sessions (4 slots) and closes the least-recently-used one on overflow. Enable/gating lives at the tools.zig call sites (`NL_BROWSER_DRIVER`); this module is pure session plumbing.

## Key Exports

- `Error` — re-export of `session.Error`.
- `navigate` / `read` / `pageText` / `click` / `typeText` / `eval` — the high-level ops; each locks, ensures the keyed session, and returns gpa-owned JSON.
- `Tile`, `renderTiles`, `Snapshot`, `renderTilesCurrent`, `freeSnapshot`, `freeTiles` — Pixel RAG's render stage: tile a page (or the current page) into fixed-height screenshots plus band text.
- `closeKey` / `closeAll` — close one keyed session / every session (the teardown hook a long-lived host calls on shutdown so no headless browser is orphaned).
- `lastActivity` / `liveCount` / `SESSION_IDLE_S` / `sweepIdle` — the activity/idle surface the local-host daemon's idle-exit runs on.
- `dispatch(gpa, io, env, key, action, params_json) []u8` — the one action dispatcher every surface funnels through (verbs: navigate, read, pagetext, click, type, eval, close, ping, rendertiles, rendertilescurrent).

## Dependencies

- `session.zig` — the per-session Session it opens and drives.
- `launch.zig` — `errText` maps browser errors to model-facing messages in dispatch results.

## Usage Context

Imported by `worker/tools.zig` (the mind's browser_* tools), `browser/broker.zig` (make_tool bodies), `browser/host.zig` (the local-host daemon), and `worker/pixelrag.zig`; `worker/run.zig` calls `closeAll` at shutdown.

## Notable Implementation Details

- Headful vs headless is a *client* selection: the desk writes `{TEMP}/nl-veil-browser.json` = `{"headful":bool}` from its Settings toggle, read per session-open (`NL_BROWSER_HEADFUL` overrides). A live session whose mode no longer matches is closed and reopened so the toggle takes effect.
- Profile dirs (and their live `DevToolsActivePort` file) must live on local disk, never OneDrive (sync locks/delays read as PortTimeout) — keyed by a hash of run_dir for per-run isolation.
- `read()` keeps CAPTCHA/interstitial pages actionable, returning their text, element refs and informational `challenge` marker. A *strong* challenge also renders screenshot tiles and splices a `visual` block so the agent can inspect and complete it; thin/canvas/SPA pages get the same visual fallback (default ON; `NL_BROWSER_PIXEL_FALLBACK=0` disables). Neither strong nor suspected challenges force a human handoff.
- `SESSION_IDLE_S = 600`: sessions used to survive until process exit, which in the daemon pinned an Edge forever and blocked its idle-exit; `sweepIdle` (called from the daemon loop and at dispatch time) ages abandoned sessions out. Generous, because a mid-conversation pause must not lose the page and a reopen costs ~1 s.
- The OOM fallback for result strings is a zero-length slice on purpose: callers free results unconditionally, and a static non-empty literal handed to `gpa.free` would be an invalid free.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
