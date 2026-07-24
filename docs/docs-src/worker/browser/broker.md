# broker

**File:** `src/worker/browser/broker.zig`  
**Module:** `worker/browser`  
**Description:** Loopback broker that lets a sandboxed make_tool Python body drive the in-process browser primitives, so RSI can invent browser-driven tools the same way it invents any tool.

---

## Purpose Summary

An authored tool runs as a Python subprocess with API keys blanked and no egress helpers injected — but it can reach 127.0.0.1 with urllib. The broker exploits exactly that: the tool composes the browser primitives by POSTing `{token,key,action,params}` to this tiny loopback HTTP server, mirroring the existing host_command broker pattern. make_tool itself is untouched; `runAuthored` (tools.zig) injects a `browser()` Python helper plus the broker url/token into the child env only when `NL_BROWSER_DRIVER` is enabled. Sessions are keyed by the tool's run_dir — the same key the mind's own browser_* tools use — so an invented tool and its author share one browser session.

## Key Exports

- `Info` — `{ port, token }` handed to callers that need to reach the broker.
- `ensure(gpa, io, env) ?Info` — lazily start the broker (idempotent, process-global); returns port + token, or null if no port in the range would bind. Pins the `gpa`/`io`/`env` the dispatched manager ops use.

## Dependencies

- `manager.zig` — every non-MCP action funnels into `browser_mgr.dispatch` (same path as the in-process tool and the daemon).
- `../mcp/discovery.zig` — `mcp_discover` / `mcp_call` actions from an invented tool's `mcp()` helper route here.
- `std.Io.net` — the raw loopback TCP server.

## Usage Context

Imported by `worker/tools.zig` (as `browser_broker`) for the make_tool injection path, and by `browser/host.zig`, whose `veil local-host` daemon is essentially this broker plus a discovery file and idle-exit loop.

## Notable Implementation Details

- Binds loopback-only and checks a per-process token, so nothing off-box can reach it. The token is splitmix64-generated hex — deliberately not crypto-grade, since it only separates this process's broker from a stray local caller; the loopback bind is the real boundary.
- Port 0 gives no way to read the assigned port back from `std.Io.net.Server`, so it scans the fixed high-port range 43110..43142 and uses the first that binds.
- A single-request-at-a-time HTTP/1.1 server on one dedicated accept thread — browser ops serialize in the manager anyway.
- Requests: POST body parsed as `{token,key,action,params}` with a 4 MiB length cap; bad token / missing key / bad JSON return `{"ok":false,...}`. Actions starting with `mcp` go to the discovery/client layer; everything else to `manager.dispatch`.

---

*Case file grounded in the module's `//!` header and public API.*
