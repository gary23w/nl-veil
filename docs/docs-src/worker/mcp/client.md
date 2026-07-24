# client

**File:** `src/worker/mcp/client.zig`  
**Module:** `worker/mcp`  
**Description:** Minimal MCP (Model Context Protocol) client — JSON-RPC 2.0 over a stdio transport, so RSI can find and use the AI-ready apps / MCP servers already installed on the user's machine.

---

## Purpose Summary

One-shot per call: spawn the server command, do the `initialize` handshake, run one `tools/list` or `tools/call`, and close. Stateless tool calls don't need a persistent connection, and a kill watchdog bounds a hung server. HTTP/SSE transport is a follow-on — stdio is what OS-installed MCP servers use.

## Key Exports

- `EnvPair` — `{ k, v }` extra environment entries for the child.
- `Server` — the launch spec: `command`, `args`, `env_extra`.
- `listStdio(gpa, io, base_env, srv, timeout_s) []u8` — the server's `tools/list` result (gpa-owned JSON), or a JSON error.
- `callStdio(gpa, io, base_env, srv, tool, arguments_json) []u8` — one `tools/call` with the given arguments object (60 s deadline), same result contract.

## Dependencies

- `std` / `builtin` only; on Windows it declares kernel32 `TerminateProcess` and `Sleep` directly for the watchdog.

## Usage Context

`mcp/discovery.zig` builds the `Server` spec from the machine's MCP config files and delegates here (discovery "finds", this module "uses"). Also imported by `cli/exec_tool.zig` and `src/plug/plugins.zig`.

## Notable Implementation Details

- The watchdog (`KillGuard`, mirroring tools.zig's spawnGuarded) polls a done flag every 150 ms and kills the child if the op runs past its deadline — a wedged MCP server must not hang the tool. Its POSIX sleep is libc `nanosleep`, not `std.os.linux`, for macOS portability.
- Protocol sequence: `initialize` (protocolVersion `2025-06-18`, clientInfo `nl-veil`), the `notifications/initialized` notification (no response), then the one real method; `finish` closes stdin (signaling the server to exit) and kill+reaps the child on every path.
- The reply reader (`recvResult`) skips interleaved notifications (no id) and mismatched ids, treats a JSON-RPC `error` as null, and re-stringifies the `result`. A 1 MiB read buffer accommodates large `tools/list`/`tools/call` results.
- The child env is a clone of the caller's with `PYTHONUTF8=1` plus the server's `env_extra`; stderr is ignored and no console window is created.
- Failures never throw — everything returns a gpa-owned JSON string, `{"ok":false,"error":...}` on error. The OOM fallback for duped strings is a zero-length slice on purpose: callers free results unconditionally, and a static non-empty literal handed to `gpa.free` would be an invalid free.

---

*Case file grounded in the module's `//!` header and public API.*
