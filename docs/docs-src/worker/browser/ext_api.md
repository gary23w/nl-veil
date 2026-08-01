# ext_api

**File:** `src/worker/browser/ext_api.zig`  
**Module:** `worker/browser`  
**Description:** The routes the browser extension speaks — identity probe, loopback-only pairing, the long poll, result delivery, goodbye — plus the authenticated status route the desk and web UI read.

---

## Purpose Summary

Six routes, each doing one thing:

| route | who may call it |
|---|---|
| `GET /api/v1/browser/ext/hello` | unauthenticated identity probe — how the extension *finds* the server |
| `POST /api/v1/browser/ext/pair` | loopback only — mints/returns the relay token |
| `GET /api/v1/browser/ext/poll` | the extension (token) — long-poll for the next CDP command batch |
| `POST /api/v1/browser/ext/result` | the extension (token) — deliver one command's reply |
| `POST /api/v1/browser/ext/bye` | the extension (token) — it is going away |
| `GET /api/v1/browser/ext/status` | authenticated — is a browser connected, and which one |

## The auth model, and why it is not the app's normal one

The extension is not a user. It is the user's own browser offering itself as a peripheral, and it has no session cookie and no API key. So these routes carry their own bearer: a token handed out **only to a caller on loopback**. That is the real boundary.

- A remote attacker cannot pair, because the request has to originate on the machine.
- A page in the user's browser cannot pair either, because it cannot read the response of a cross-origin POST it is not allowed to make.
- Even if pairing leaked, the relay's blast radius is one tab the extension itself opened.

Loopback is decided from the **socket** (`127.0.0.0/8` or `::1`), never from a header — `X-Forwarded-For` is attacker-controlled and is deliberately ignored, so a reverse proxy in front of the server cannot forge local origin. The token is compared in full and never logged.

**CORS is deliberately absent.** An MV3 service-worker fetch is not a page fetch and is exempt from CORS given host permissions, so adding `Access-Control-Allow-Origin` here would only open the relay to web pages.

## Key Exports

- `PROTOCOL` — bumped when the server↔extension wire contract changes shape. The extension sends its version on every poll, and a mismatch is *reported to the user* rather than silently half-working.
- `hello`, `pair`, `poll`, `result`, `bye`, `status`, `live`, `relay` — the handlers, registered by `src/main.zig`.
- `becomeHost` — re-exported from `ext.zig` so main publishes the relay through the same module it registers the routes from; called once at boot, when the port is known.

## Dependencies

`ext.zig` (all connection state and the slot table), `../../gateway/http.zig` (`App`, `requireUser`), and `httpz`.

## Usage Context

`src/main.zig` mounts these under `/api/v1/browser/ext/`. The desk and the web UI poll `status` to show whether a browser is linked; the extension in [`extension/`](https://github.com/gary23w/nl-veil/tree/main/extension) speaks the other five.

## Notable Implementation Details

- `hello` answers with nothing that isn't already implied by the port being open (`{ok, app, protocol}`) — it exists so the extension can sweep a handful of loopback ports and find the server before it holds any credential.
- The handler tests run through the real HTTP surface (`http.testApp` + `httpz.testing`), including the loopback check, so the boundary is verified where it is enforced rather than in an extracted helper.

---

*Case file grounded in the module's `//!` header and public API.*
