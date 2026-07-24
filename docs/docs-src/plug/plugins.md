# plugins

**File:** `src/plug/plugins.zig`  
**Module:** `plug`  
**Description:** The veil plugin registry — user extensions loaded from `<data>/plugins/`, one folder per plugin, each driven by a Lua manifest (`plugin.lua`) running in the lua.zig sandbox.

---

## Purpose Summary

A plugin declares up to three hook families, all optional. TOOLING: `veil.tool{...}` registers a model-callable tool with a Lua handler; `veil.mcp{command=...}` bridges an external MCP server's whole tool list (spawned per call via the existing stdio client). Plugin tools are advertised to the model as `plug_<plugin>_<tool>` alongside the built-ins and dispatched here instead of tools.zig. POLICY: `veil.on_policy(fn)` sees every chat-surface tool call (uid, tool, args, conv, admin) BEFORE it runs and can deny it with a reason — first deny wins, and a hook that errors FAILS OPEN (loudly logged): a buggy plugin must not brick the app. PROMPTS: `veil.on_prompt(fn)` returns extra system-prompt text that rides the per-turn recall channel, never the stable prefix, so provider prompt-prefix caching is unharmed.

## Key Exports

- `Registry` — the immutable-after-load set: `findTool`/`ownsTool`, `policyGate` (null = allowed, else a gpa-owned "(...)"-shaped refusal), `promptText` (clipped per plugin and overall), `execTool` (always returns a string — plugin errors come back as "(...)" strings, never Zig errors), `listJson` (the /api/v1/plugins payload), plus the ready-to-append `schemas` chunk and the `themes` workspace
- `loadAll` — build a registry from `<data>/plugins/*/plugin.lua` + the theme workspace; never fails (a broken plugin loads as state=failed with its error kept; a missing dir yields an empty set)
- `current` / `swap` — atomic acquire/release pointer helpers for the App's registry slot
- `Plugin` / `PlugTool` / `ToolKind` / `State` / `LoadOptions` — the data model (`skip_mcp_listing` for unit tests / offline boots)
- `MAX_PLUGINS` (24) / `MAX_TOOLS_PER_PLUGIN` (16) / `NAME_MAX` (24)

## Dependencies

- `lua.zig` — the sandboxed Vm each manifest and hook runs in
- `theme.zig` — the theme workspace, loaded alongside plugins so one reload refreshes both (plus the themes.json cache for the desk)
- `../worker/mcp/client.zig` — `listStdio`/`callStdio` for the MCP bridge
- Deliberately NO other app modules: gateway/http.zig holds a `?*Registry` field, so importing http here would cycle

## Usage Context

main.zig calls `loadAll` at boot and again on the admin reload endpoint, swapping the App's slot via `swap`; chat turns consult `policyGate`/`promptText`/`execTool` through `current`.

## Notable Implementation Details

- Threading: the registry is immutable after load; each plugin owns ONE Lua state guarded by its own mutex, so every host→Lua entry serializes per plugin (hooks are expected to be micro-functions; heavy work belongs in tools).
- Reload is a whole-registry rebuild + pointer swap; the old registry is deliberately leaked so in-flight turns keep reading a valid one — a rare admin action, bounded and documented.
- The manifest API (`veil.plugin/tool/on_policy/on_prompt/mcp`) is load-time only: `loading` flips off after plugin.lua finishes and later registration raises. `print` inside plugin VMs is rerouted to `veil.log`.
- `veil.read_file` is scoped to the plugin's own folder (relative paths only, no `..`, no drive letters); tool params come from validated `params_json` or a synthesized schema from a `params` table.
- Plugin folders load in sorted order (deterministic hook order); a `.disabled` marker file skips a folder entirely; combined tool names are capped at 64 chars.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
