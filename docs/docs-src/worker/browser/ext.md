# ext

**File:** `src/worker/browser/ext.zig`  
**Module:** `worker/browser`  
**Description:** The browser-EXTENSION transport — a CDP relay through a Chrome/Edge extension the user already has open, so the driver can work inside the browser they are signed into instead of a throwaway profile.

---

## Purpose Summary

The original driver (`launch.zig` + `cdp.zig`) spawns its *own* browser on a temp profile that is logged out of everything — which is why launch carries hundreds of lines of sync suppression, profile seeding, first-run flags and `navigator.webdriver` scrubbing. All of that is the cost of not being the user's real browser. Attaching to the browser they are already signed into removes the whole category: their cookies, their sessions, their extensions, and a human sitting right there to answer a verification prompt.

The extension itself is deliberately as close to nothing as possible. It relays `{method, params}` to `chrome.debugger.sendCommand` and posts the reply back. It holds **no** automation logic — no snapshot script, no ref model, no click heuristics. Those stay in `session.zig` and travel to the page inside `Runtime.evaluate` payloads, so changing the snapshot never means reinstalling an extension. (MV3 forbids `executeScript({code})`, but the debugger protocol evaluates freely — which is exactly why the relay is a debugger relay and not a content script.) It also means input is **trusted**: `Input.dispatchMouseEvent` and `Input.insertText` through `chrome.debugger` are the same real events the session model already relies on, not the `isTrusted:false` synthetics a content script is limited to.

## Transport

The extension polls *us*; the server never dials it. An MV3 service worker cannot listen for connections, and an in-flight `fetch` is what keeps it alive — so `GET /poll` long-polls for the next command batch and `POST /result` returns each answer. No websocket: a long poll needs nothing that isn't already here.

## Key Exports

- `available(gpa, io, env)` / `status(io)` — is an extension connected right now, and which browser is it (`Status`).
- `call(...)` / `callLocal(...)` — issue one CDP method with params and an optional session id, blocking until the extension delivers or the deadline passes; `Error` is `NotConnected | Timeout | ExtError | OutOfMemory`.
- `takeCommands(gpa, io, wait_ms)` / `deliver(gpa, io, id, payload, failed)` — the server side of the long poll: hand the extension its next batch, take back one reply.
- `ensureToken(io)`, `loadOrMintToken(io, gpa, data_dir)`, `tokenOk(io, tok)` — the relay bearer, minted once and **persisted**, so a server restart does not un-pair the browser.
- `heartbeat(io, browser, version, paused)` / `disconnect(io)` — liveness (`LIVE_TTL_MS`) and a clean goodbye.
- `becomeHost(gpa, io, env, port)` — publish this process as the relay host for the machine.

## Dependencies

`util.zig` for raw-thread-safe sleeping (callers are httpz request workers, worker threads and the `exec-tool` thread — none of them Io-managed tasks, so this must never touch `io.sleep`), `../httpc.zig` for the cross-process hop, and the standard library.

## Usage Context

`ext_api.zig` serves the routes the extension speaks; `manager.zig`/`session.zig` prefer this transport when an extension is connected and fall back to a launched browser when it is not.

## Notable Implementation Details

- **Concurrency.** Commands park in a fixed slot table and the caller blocks on `util.sleepMs` until delivery or deadline — no async machinery, and nothing that assumes an Io context.
- **One extension, many processes.** The extension pairs with the *server*, but browser tools do not all run there: the desk delegates each one to a fresh `veil exec-tool` subprocess, which forwards to the per-machine `local-host` daemon. Those are different processes and this module's connection state is process-global, so without the host bridge the daemon would see no extension and quietly launch its own browser — the exact bug half of this file exists to prevent.
- The poll deadline (`POLL_MAX_MS`) is under the service worker's patience, and liveness expires (`LIVE_TTL_MS`) rather than being trusted forever, so a browser that vanished is reported as gone instead of hanging the next call.

---

*Case file grounded in the module's `//!` header and public API.*
