# discovery

**File:** `src/worker/mcp/discovery.zig`  
**Module:** `worker/mcp`  
**Description:** Discover the AI-ready capabilities already installed on the user's machine — MCP servers declared in known config files plus local AI-runtime endpoints found by probing well-known ports.

---

## Purpose Summary

This is how the RSI system "finds" local AI apps; mcp/client.zig is how it "uses" them. It scans the config files of Claude Desktop, Cursor, and VS Code for declared MCP servers, and probes well-known loopback ports for live AI runtimes. Config scanning is read-only and never returns env values (they may hold secrets) — only the server name, source, transport, and command/url. `serverTools`/`callServer` connect to a named stdio server on demand.

## Key Exports

- `discoverAll(gpa, io, env) []u8` — `mcp_discover` with no `server`: list all MCP servers from the config files + probe known local AI runtimes into `{ok, mcp_servers, ai_runtimes}`. Read-only; spawns nothing.
- `serverTools(gpa, io, env, name) []u8` — `mcp_discover` with a `server`: connect to it and return its `tools/list`.
- `callServer(gpa, io, env, name, tool, arguments_json) []u8` — `mcp_call`: run `tool` on the named stdio server.

## Dependencies

- `client.zig` — `listStdio`/`callStdio` once a named server's launch spec is assembled.
- `../httpc.zig` — the runtime port probes (2 s timeout, 8 KiB cap; "up" = any status under 500).

## Usage Context

Imported by `worker/tools.zig` (the mind's discover/call surface) and by `browser/broker.zig`, whose `mcpDispatch` routes an invented tool's `mcp()` helper calls here.

## Notable Implementation Details

- Config candidates cover Claude Desktop (Windows APPDATA, macOS Library, Linux .config), VS Code user `mcp.json` (Windows and home), and Cursor's global `~/.cursor/mcp.json`; both root shapes are accepted (`mcpServers` for Claude/Cursor, `servers` for VS Code).
- Transport is inferred per entry: a `url` means `http`, otherwise `stdio`. Calling an http-transport server returns an explicit "not yet supported (stdio only for now)" error rather than a silent failure.
- Runtime probes: port 11434 `/api/version` (ollama), 1234 `/v1/models` (lm-studio), 8080 `/v1/models` (generic openai-compatible endpoint).
- `withNamedServer` rebuilds the launch spec from the config on every call — command, string args, and string env entries — then hands it to the client; a name found in no config file returns "server not found in the local MCP config files".
- The OOM fallback for duped strings is a zero-length slice on purpose (callers free results unconditionally; a static non-empty literal handed to `gpa.free` would be an invalid free).

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
