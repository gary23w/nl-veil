# garrett

**File:** `src/worker/garrett.zig`
**Module:** `worker`

The Agent Garrett MCP client discovers tools and gives the chat engine and swarm workers their original schemas. The v1.1.12 cloud deployment advertises 166 tools once Gary is ready. Each tool is exposed to the model as `security_<upstream_name>`; `garrett_tools` and `garrett` remain available as compatibility wrappers.

## Discovery and dispatch

`discover` requests `tools/list` from the user's authenticated MCP endpoint. `renderDefs` renders each tool as a `security_<name>` function def, **terse**: names, types, enums, nested objects and arrays and the `required` list are preserved exactly; validation constraints (`maxLength`, `pattern`, bounds) are dropped, a tool's description keeps its leading sentences up to `DEF_DESC_MAX` (200 bytes) and an argument's up to `ARG_DESC_MAX` (80), and an object with more than `ARG_BAG_MIN` (16) named arguments is treated as an alias bag: its required arguments stay typed, `additionalProperties` is true, and the remaining names are listed in the object's description so the model still spells every key the upstream way. Measured on the first long chat with the catalogue (conv c6ac996e9, 2026-10-10) the verbatim schemas were 366 KB of a 405 KB tools array — 257 KB of it one identical 54-argument bag on 94 tools — re-uploaded on every inference; terse, the same catalogue is ~140 KB. Calls still pass their JSON argument objects without converting values into strings. `renderList` includes the full input schemas for compatibility discovery.

The terse belt is a constant-factor fix. The structural one is the [tool map](../worker/chat/belt.md): the catalogue compiles into a tree the model walks a branch at a time, and its 166 tools cost nothing until one is wanted.

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
