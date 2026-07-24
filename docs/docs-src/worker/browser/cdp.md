# cdp

**File:** `src/worker/browser/cdp.zig`  
**Module:** `worker/browser`  
**Description:** Chrome DevTools Protocol client — a synchronous request/response wrapper over a minimal, self-contained RFC-6455 WebSocket client built on std.Io.net.

---

## Purpose Summary

CDP is JSON-RPC over one ws connection: this module sends `{"id":N,"method":...,"params":...,"sessionId":...}` and reads frames until the reply carrying its `id` arrives, discarding the interleaved event frames. It deliberately does not use the vendored websocket.zig client: that one is a blocking raw-socket implementation off the app's std.Io model, and its read-timeout path uses `std.posix.poll`, whose `pollfd` is absent from this Zig's Windows ws2_32 — so it does not compile on Windows here. CDP is plaintext loopback ws with small text frames (plus a few multi-MB screenshot frames), so a purpose-built client is simpler than forking a shared dependency and keeps the code on std.Io like httpc.zig.

## Key Exports

- `Error` — `{ Connect, Handshake, Send, Closed, CdpError, BadReply, OutOfMemory }`.
- `Cdp` — the connection struct:
  - `connect(gpa, io, port, ws_path)` — TCP connect + ws upgrade to `ws_path` on 127.0.0.1:`port`.
  - `call(method, params_json, session_id)` / `callTimeout(...)` — issue one CDP command; returns its `result` object as a gpa-owned JSON string. A CDP `error` reply maps to `error.CdpError`. `timeout_ms` is currently advisory.
  - `deinit()` — close the stream and free the buffers.

## Dependencies

- `std` only (`std.Io.net` raw sockets, `std.json`) — no vendored ws library.

## Usage Context

Consumed by `browser/session.zig`, which connects once per browser process and issues Target/Page/Runtime/Input commands (with a flattened page `sessionId`) over this single ws.

## Notable Implementation Details

- Explicit `Host: 127.0.0.1:<port>` header on the upgrade: Chromium's DevTools endpoint validates the Host header (a DNS-rebinding guard) and rejects a request lacking a loopback Host.
- Reads are blocking, bounded by connection liveness rather than a wall clock: every id'd command gets a reply, `Page.navigate` returns as soon as navigation is initiated, and readiness is polled at the JS layer — so no single call waits unboundedly. A dead browser surfaces as a socket error mapped to `error.Closed`.
- RFC-6455 requires client frames to be masked; on a direct loopback connection the mask key need not be unpredictable, so a cheap splitmix64 supplies it (masking is anti-proxy-cache, not a secret) — avoiding `std.crypto.random` (absent in this Zig) or a time source.
- Reader/writer are heap-boxed because `Io.Reader` uses `@fieldParentPtr`, so their addresses must be stable; a reused frame-reassembly buffer holds fragmented messages.

---

*Case file grounded in the module's `//!` header and public API.*
