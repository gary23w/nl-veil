# exec_tool

**File:** `src/cli/exec_tool.zig`  
**Module:** `cli`  
**Description:** The shared client-side tool executor — `veil exec-tool <name>` runs a tool through the server's own tools.execute in the invoker's working directory, so no tool is reimplemented per client.

---

## Purpose Summary

When a server chat turn delegates a `tool_request` to a client, the tool must run on the USER's machine — and there must be exactly ONE implementation of every tool. This file is that bridge: `runTool` builds a client-side `ToolCtx` rooted at a workdir and hands the call to `tools.execute`. The CLI chat calls it in-process; the desk (a separate package) spawns the `veil exec-tool` subcommand and captures stdout. Sibling verbs answer the workdir-sync frames the same way (`sync-manifest`, `sync-read`), and a set of smoke harnesses exercises the browser, MCP, and pixel tool layers end to end through the same executor.

## Key Exports

- `runTool` — run one tool with a client context at `workdir`; always returns a gpa-owned string (even on error), the tools.execute result contract
- `cmd` — the `veil exec-tool <name> [--workdir DIR] [--args-file PATH]` verb: args JSON from a file or stdin, result on stdout
- `cmdSyncManifest` / `cmdSyncRead` — subprocess twins of the CLI's in-process `sync_request` / `file_pull` handlers, used by the desk
- `browserFlowSmoke` — browser_navigate → browser_read → browser_close through tools.execute, proving the persistent session carries across calls
- `browserInventSmoke` — make_tool registers a browser-driving tool, then invokes it (the injected `browser()` helper → loopback broker → shared session)
- `mcpSmoke` / `mcpInventSmoke` — mcp_discover + the stdio MCP client against a bundled mock server; an invented tool calling `mcp()`
- `pixelSmoke` — pixel_ingest a URL then pixel_search a query

## Dependencies

- `../worker/tools.zig` — `ToolCtx` + `execute`, the single tool implementation
- `../worker/oscillation.zig` — `Mem.init` for the client memory store (neuron binary at `{home}/bin/neuron[.exe]`)
- `../worker/chat/sync.zig` — `safeRoot`, `manifestResponse`, `readResponse` for the sync verbs
- `../worker/mcp/client.zig` — the stdio MCP client the mock-server smoke drives directly
- `../cli.zig` — `Ctx` and stdout output

## Usage Context

Wired into `cli.zig`'s dispatcher as the `exec-tool`, `sync-manifest`, and `sync-read` verbs; `cli.zig`'s `runDelegatedTools` calls `runTool` in-process for the CLI chat's client mode. The smoke functions are exported harness entry points.

## Notable Implementation Details

- CLIENT privilege: the delegated-tool `ToolCtx` sets `.roam = true` (read-only tools may take absolute/`~` paths; stage_file may copy outside files into the workdir) because this executor runs on the user's own machine at the user's own request — swarm minds never get it.
- `.browser_daemon = true`: a fresh exec-tool process per delegated call cannot hold a browser session, so browser/pixel tools route to the persistent per-machine daemon instead of an in-process manager.
- The sync verbs refuse a non-`.` workdir that fails `cync.safeRoot` by answering an EMPTY manifest/file list — never a substitute directory.
- The smokes gate on environment: `NL_BROWSER_DRIVER=1` for browser/pixel, `NL_MCP=1` for MCP discovery.

---

*Case file grounded in the module's `//!` header and public API.*
