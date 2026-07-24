# session

**File:** `src/worker/browser/session.zig`  
**Module:** `worker/browser`  
**Description:** One headless browser session — process + CDP connection + an attached page — plus the high-level surface everything above uses.

---

## Purpose Summary

Pixel RAG calls `screenshotBase64()` to tile a page; the RSI browser tools call navigate/snapshot/clickRef/typeRef/evaluate. One Session is built per feature-run and `close()`d on teardown. The page is driven at the DOM level (JS via Runtime.evaluate) rather than by synthetic input coordinates: simpler and more robust for headless automation, and it gives every interactive element a stable `data-nlref` id that `snapshot()` returns and `clickRef()`/`typeRef()` act on — the same ref model the app's own browser tooling exposes.

## Key Exports

- `Error` — `{ NoBrowserFound, Launch, PortTimeout, Connect, Protocol, EvalFailed, OutOfMemory }`.
- `OpenOpts` — `{ user_data_dir (required), headless = true, width, height }`.
- `Session` — `open` / `close` / `navigate` / `harden` / `evaluate` / `screenshotBase64` / `snapshot` / `pageMetrics` / `screenshotClipBase64` / `bandText` / `clickRef` / `typeRef`.
- `smoke(gpa, io, env, url)` — the `veil browser-smoke <url>` end-to-end exercise: launch headless, navigate, snapshot, screenshot to `browser-smoke.png`, close, print a summary.

## Dependencies

- `launch.zig` — discover the browser, spawn it, read the DevTools endpoint.
- `cdp.zig` — the ws command channel (`Cdp.call`/`callTimeout`).
- `util.zig` — raw-thread-safe sleeps in the readiness poll.

## Usage Context

`browser/manager.zig` opens one Session per registry key; `src/main.zig` routes `veil browser-smoke` to `smoke()`. `smoke` is how the shared layer is verified without adding a browser-spawning unit test to the suite (slow and Defender-flaky on this machine).

## Notable Implementation Details

- `open()` resolves the profile dir to an absolute path: the browser resolves a relative `--user-data-dir` against *its* cwd while `readEndpoint()` resolves the port file against *ours*, and a mismatch reads as a timeout. It then creates a page target and attaches with `flatten:true`, so page commands ride the one ws with a `sessionId`.
- `close()` issues `Browser.close` — the reliable kill, since headless Edge daemonizes (the spawned process exits immediately, handing off to detached children the Child handle no longer refers to) — then tears down the ws and reaps the launch handle.
- `navigate()` waits (bounded) for `document.readyState === "complete"`, re-arms `harden()` on the fresh JS context, and returns the final URL.
- `harden()` neutralizes the two things that silently break headless click-through: modal JS dialogs and popups. The CDP client discards event frames, so it never answers `Page.javascriptDialogOpening` — a native `alert()`/`confirm()`/`beforeunload` would block the renderer and hang the next evaluate. alert/confirm/prompt become non-blocking, beforeunload can't veto a navigation, and popups are coerced into the same tab. Best-effort and idempotent; re-run after every navigation.
- `clickRef()` sends real trusted input (`Input.dispatchMouseEvent`, `isTrusted:true` — accepted by bot-protection and strict event validators, unlike a JS `el.click()`): scroll into view, resolve the viewport-center point, move → press → dwell → release, then settle any navigation so a following read sees the landing page. Falls back to a synthetic click only when the element can't be localized.
- Screenshot base64 is never decoded server-side — Pixel RAG persists it as-is and hands it to a vision model verbatim.

---

*Case file grounded in the module's `//!` header and public API.*
