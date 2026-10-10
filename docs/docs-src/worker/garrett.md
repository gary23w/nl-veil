# garrett

**File:** `src/worker/garrett.zig`
**Module:** `worker`

The Agent Garrett MCP client discovers tools and gives the chat engine and swarm workers their original schemas. The v1.1.12 cloud deployment advertises 166 tools once Gary is ready. Each tool is exposed to the model as `security_<upstream_name>`; `garrett_tools` and `garrett` remain available as compatibility wrappers.

## Discovery and dispatch

`discover` requests `tools/list` from the user's authenticated MCP endpoint. `renderDefs` preserves the individual names, descriptions and input schemas. Nested objects, arrays, booleans and numbers remain typed; calls pass their JSON argument objects without converting values into strings. `renderList` includes the full input schemas for compatibility discovery.

`run` handles the wrappers and individual `security_` names. Tool-call text and evidence metadata return to the model; JSON-RPC errors and failed tool results remain visible as failures. `runtimeStatus` calls the authenticated `gary/runtime/status` RPC so Settings can track preparation independently of the initial upload request.

## Exports

- `SCHEMA`: compatibility definitions for `garrett_tools` and `garrett`.
- `Ctx`, `run`: allocator, I/O, scratch directory, user credential pair and one dispatch.
- `discover`, `renderDefs`, `renderList`: catalogue discovery and typed presentation.
- `runtimeStatus`: cloud execution-runtime phase and error.
- `isTool`, `toolName`, `on`, `allowedUrl`: namespace recognition, upstream-name validation and credential/address checks.

## Routing and ownership

In desktop or CLI client mode, security calls run on the server. Their MCP bearer stays out of delegated-tool events. Swarm workers use the pair prepared in their private run credentials. Online sandboxed turns can use their own opted-in deployment; offline turns do not make network calls. Authentication, per-user resolution and destination validation remain in place.

Tests cover discovery, typed nested arguments, direct dispatch, compatibility wrappers, error rendering, absent credentials and credential-safe scratch handling. The release also exercises cloud commands, shell listing and indicator extraction through a live NL-Veil chat.

See [the security guide](../guide/security-tools.md) and [credential resolution](../config/cf_garrett.md).
