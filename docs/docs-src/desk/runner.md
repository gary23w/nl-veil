# runner

**File:** `desk/src/runner.zig`  
**Module:** `desk`  
**Description:** The location-agnostic execution surface the chat engine holds instead of calling netcli (or spawning shell) directly.

---

## Purpose Summary

The engine reaches the outside world ONLY through a `Runner`, so when the chat brain later moves in-process into the backend, only the Runner implementation changes — no engine edits. Today's one implementation, `LocalRunner`, forwards each verb verbatim to the loopback server via netcli; a future RemoteRunner (cloud backend delegating to a desk-agent) or in-process ServerRunner (brain moved server-side) implements the same VTable.

## Key Exports

- `Resp` — re-export of `netcli.Resp` (`{status: u16, body: []const u8}`)
- `Runner` / `Runner.VTable` — the ctx+vtable interface with nine verbs: `runTool` (POST /api/v1/chat/tool), `cast` (POST /api/v1/cast), `chatSend` (one server-side turn), `chatEvents` (byte-cursor poll of a conv's frames), `chatControl` (cooperative ops like `{"op":"stop"}`), `chatConvs` / `chatConv` / `chatDelete` (the server conversation list / one log / removal), and `chatToolResult` (client mode: return a delegated tool's result to the blocked turn). Every verb returns `?Resp`, null meaning unreachable
- `local` — construct the loopback-backed Runner over the shared Store

## Dependencies

- `netcli.zig` — the actual HTTP calls each local verb forwards to
- `store.zig` — the shared Store the LocalRunner reads port + bearer token from

## Usage Context

`desk/src/chat.zig` imports this module and drives everything server-side through it; `local(store)` is the wiring for today's behavior, verbatim.

## Notable Implementation Details

- The LocalRunner reads the CURRENT port + bearer token from the store on EACH call (snapshotted under the store lock into a caller buffer) — settings can change at runtime, so they cannot be cached. This is exactly what the old direct call sites did.
- `ctx` is a type-erased `*anyopaque` (the Store for the local vtable), keeping the interface implementation-agnostic.

---

*Case file grounded in the module's `//!` header and public API.*
