# Writing a plugin

A plugin adds capability to veil: new **tools** the AI can call, a **policy** that gates what runs, and
**prompt** text that shapes every turn. It's a folder under `<data>/plugins/` with a `plugin.lua` manifest,
evaluated once at load in a locked-down Lua 5.4 sandbox.

Because the hooks live in the server engine, a plugin affects the AI wherever it runs — a desktop chat, a
web chat, a scheduled task, or a swarm.

## The manifest

`plugin.lua` runs at load and calls `veil.*` to register what it provides. Declare the plugin first:

```lua
veil.plugin{
  name        = "greeter",       -- REQUIRED, [a-z0-9_], ≤24 chars, unique across plugins.
  version     = "1.0",
  description = "adds a hello tool and a house-style prompt",
}
```

The name becomes the prefix of every tool: `plug_<name>_<tool>`.

## Tools — `veil.tool`

Registers a model-callable tool. The AI sees it alongside the built-ins.

```lua
veil.tool{
  name = "wordcount",
  description = "Count the words in some text.",   -- the model reads this to decide when to call it
  params = {
    text   = { type = "string",  description = "text to count", required = true },
    unique = { type = "boolean", description = "count distinct words only" },
  },
  handler = function(args)
    local n = 0
    for _ in tostring(args.text or ""):gmatch("%S+") do n = n + 1 end
    return { ok = true, words = n }
  end,
}
```

- **Parameters** — use the friendly `params = { name = { type=, description=, required= } }` form, or supply
  a raw `params_json = [[ {...JSON schema...} ]]` string for full control (validated at load).
- **Return** a string (used verbatim), a table (serialized to JSON), or nil (becomes `{"ok":true}`).
- **Errors** — `error("...")` in a handler is caught and returned to the model as a clean message; a buggy
  tool never crashes the app.

MCP servers can be bridged instead of hand-writing tools — see [MCP bridge](#mcp-bridge) below.

## Policy hooks — `veil.on_policy`

See **every** tool call before it runs and optionally deny it. Enforce guardrails, restrict tools to
admins, require argument shapes, or log usage.

```lua
veil.on_policy(function(ctx)
  -- ctx = { uid, admin, conv, tool, args_json }
  if ctx.tool == "host_command" and not ctx.admin then
    return { allow = false, reason = "host commands are admin-only here" }
  end
  return true   -- allow (nil also allows)
end)
```

Verdict: `true`/`nil` = allow; `false` = deny (generic); `{ allow = false, reason = "…" }` = deny with a
message shown to the model.

- The **first** denying plugin wins.
- A hook that **errors fails open** (the call proceeds, logged) — a broken policy plugin can't brick tool
  use. Guard your logic and test with a bare `return false` first to confirm it fires.
- Parse arguments with `veil.json_decode(ctx.args_json)` when you need specific fields.

## Prompt hooks — `veil.on_prompt`

Return extra system-prompt text for a turn — a house style, a compliance note, project context.

```lua
veil.on_prompt(function(ctx)
  -- ctx = { uid, admin, conv }
  return "House style: be concise, cite sources, never use emoji."
end)
```

Return a string (or nil/empty to add nothing). It rides the per-turn channel, so it never breaks provider
prompt caching. Keep it short — there is a per-plugin clip.

## MCP bridge

Bridge an external **MCP server**; all of its tools become veil tools (`plug_<name>_<toolname>`).

```lua
veil.plugin{ name = "fsmcp", description = "bridges an MCP filesystem server" }
veil.mcp{
  command   = { "npx", "-y", "@modelcontextprotocol/server-filesystem", "/allowed/path" },
  env       = { SOME_TOKEN = "..." },
  timeout_s = 20,
}
```

At load, veil lists the server's tools once and registers each. On a call it spawns the server over stdio,
runs the tool, and returns the result; a hung server is killed by a watchdog. If the server can't be
listed (not installed, bad command), the plugin loads as `failed` with the error — it never blocks the
rest.

## The `veil.*` API

| function | when | description |
|---|---|---|
| `veil.plugin{ name=, version=, description= }` | load | Declare the plugin. Call first. |
| `veil.tool{ name=, description=, params=/params_json=, handler= }` | load | Register a model-callable tool. |
| `veil.on_policy(fn)` | load | Register the policy hook `fn(ctx) -> verdict`. |
| `veil.on_prompt(fn)` | load | Register the prompt hook `fn(ctx) -> string`. |
| `veil.mcp{ command={...}, env={...}, timeout_s= }` | load | Bridge an MCP server's tools. |
| `veil.log(...)` | anytime | Log to the server log (also the global `print`). |
| `veil.json_decode(s)` / `veil.json_encode(v)` | anytime | JSON ↔ Lua table. |
| `veil.read_file(rel)` | anytime | Read a file inside your plugin folder (relative, no `..`). |

You can also `require("util")` to load `<your plugin>/util.lua` — scoped strictly to your own folder.

## The sandbox & security model

Plugins are untrusted by default and run with hard limits so a buggy or hostile plugin can't damage the
host, hang a chat, or exfiltrate data on its own.

**Allowed:** pure computation (`string`, `table`, `math`, `utf8`, `coroutine`, and the clock/date parts of
`os`), registering tools/hooks, and reading files inside the plugin's own folder.

**Blocked:** no `io`, no `os.execute`/`getenv`/`remove`/`exit`, no `debug`, no `package`/C loader, no
`dofile`/`loadfile`. `load()` accepts **text only** — bytecode is rejected. No filesystem access outside
the plugin folder. No raw sockets or process spawning (reach the outside world only through a deliberate
tool or an MCP bridge).

**Limits per call:** an **instruction budget** stops a runaway loop; a **memory cap** stops a string/table
bomb; MCP child processes are killed by a watchdog.

**Failure is contained:** a plugin that throws at load becomes `state = failed` with its error kept — other
plugins are unaffected. A hook that errors at runtime fails open (policy) or is skipped (prompt) and bumps a
`hook_errors` counter visible in `veil plugins`.

**Still applies:** plugin tools run through the same policy gate (including other plugins' policies) and do
**not** bypass veil's capability gates — a sandboxed, non-admin user can't reach admin-only built-ins
through a plugin. Because a plugin is code you install, read third-party `plugin.lua` files before running
them; the sandbox limits blast radius, it isn't a licence to run unknown code blindly.

## Load, reload, disable

- Confirm a plugin: `veil plugins` (a `failed` row shows the exact error in its `ERROR` column).
- After editing: `veil plugins reload` (admin) hot-swaps the live registry with no restart; in-flight turns
  keep the version they started with.
- Disable without deleting: drop an empty `.disabled` file in the plugin's folder.

See also: [Extending veil](#doc=guide/extensions) · [Authoring a theme](#doc=guide/themes). The full
reference is `PLUGINS.md` at the repo root.
