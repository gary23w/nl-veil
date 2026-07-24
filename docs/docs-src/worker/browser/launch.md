# launch

**File:** `src/worker/browser/launch.zig`  
**Module:** `worker/browser`  
**Description:** Headless-browser discovery and process launch for the shared CDP session — the single place a browser process is found, spawned, and located on the DevTools wire.

---

## Purpose Summary

Pixel RAG's render stage and the RSI browser driver both drive one of these. Nothing is bundled or installed: every Windows box already ships Edge, so the module discovers the Chromium-family browser already present and spawns it headless with an OS-assigned debugging port. Process handling mirrors control/supervisor.zig — the caller owns the returned `Child` and must kill/reap it.

## Key Exports

- `Error` — `{ NoBrowserFound, PortFileTimeout, BadPortFile }`.
- `Family` — `enum { chrome, edge, chromium }`: a family *preference* among installed browsers, never an arbitrary path.
- `setPreferredBrowser(name)` — publish the admin's family preference (`""` | `"chrome"` | `"edge"` | `"chromium"`); called from server_config whenever its `browser` field changes.
- `discover(gpa, io, env) Error![]u8` — resolve the browser executable path (gpa-owned).
- `notFoundHint()` / `errText(e)` — model-facing remediation text: `NoBrowserFound` becomes an actionable "install Edge/Chrome or set NL_BROWSER_BIN" message instead of a bare error name.
- `Opts` — `{ headless, width, height }`; the viewport doubles as the default Pixel RAG tile size.
- `spawn(gpa, io, browser_path, user_data_dir, opts) !std.process.Child` — launch headless with `--remote-debugging-port=0`, isolated to the profile dir.
- `Endpoint` / `readEndpoint(gpa, io, user_data_dir, timeout_ms)` — poll `DevToolsActivePort` for the chosen port + browser-level ws path.

## Dependencies

- `util.zig` — `sleepMs` in the port-file poll loop.
- `builtin` — OS switch between the Windows and POSIX candidate lists.

## Usage Context

`session.Session.open` calls `discover` → `spawn` → `readEndpoint`. The preference publisher `setPreferredBrowser` is called from server_config (config → launcher push), because `discover()` is reached with only an env map and no ServerConfig handle.

## Notable Implementation Details

- Resolution order: `NL_BROWSER_BIN` (a full exe path) overrides everything; then the preferred family (`NL_BROWSER` env wins over the published server_config preference) is tried first *only when actually installed*; then the historical Edge-first candidate list; finally, on Windows, a `reg query` of the msedge.exe App Paths key catches a non-default install location.
- The published preference lives in a small buffer with a release/acquire length so an in-flight `discover()` never observes a torn slice (single-writer: server_config serializes its own writes).
- `spawn` deletes any stale `DevToolsActivePort` first so `readEndpoint` waits for the *new* process's port, never a previous run's; stdio is ignored and no console window pops.
- Promo suppression is two-layered: launch flags (`--disable-sync`, a single-CSV `--disable-features=msImplicitSignin,...` switch, and more) plus a once-only pre-seeded profile (`First Run` marker and a `Default/Preferences` that disables sign-in/sync) — a headful Edge that Windows-SSO implicitly signs in would otherwise pop a sync-confirmation modal that lives in browser chrome, unreachable by snapshot/click. Turning `AutomationControlled` off drops the `navigator.webdriver` fingerprint at the source so the user's own assistive session isn't pre-emptively degraded — the comment states this is not captcha evasion.
- `readEndpoint` parses the two-line port file (port, then `/devtools/browser/<uuid>`), retrying while the ws line has not been flushed yet.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
