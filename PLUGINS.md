# Building for veil — Plugins, Themes & Add-ons

veil is extensible. You can add your own **themes** (re-skin the whole product) and your own
**plugins** (new tools the AI can call, policies that gate what runs, and prompt text that shapes every
turn) — all as small files you drop into a folder. No rebuild, no fork. Everything you author works across
the **entire ecosystem**: the desktop app, the web app, and the CLI.

Plugins are written in **Lua**, evaluated in a locked-down sandbox. Themes are tiny Lua files too. This
guide tells you exactly how to build both, from a one-line theme to a full plugin that hooks tools,
policies, and prompts — and how to bridge an external MCP server.

> **Audience note (humans and AI both):** this file is self-contained. If you are an AI assistant asked to
> "write a veil plugin/theme", everything you need is here — the directory layout, the full `veil.*` API,
> the sandbox rules, and copy-paste templates.

---

## Table of contents

1. [Where things live](#1-where-things-live)
2. [Quickstart: a theme in 60 seconds](#2-quickstart-a-theme-in-60-seconds)
3. [Quickstart: a plugin in 2 minutes](#3-quickstart-a-plugin-in-2-minutes)
4. [Themes in depth](#4-themes-in-depth)
5. [Plugins in depth](#5-plugins-in-depth)
   - [The manifest](#the-manifest-veilplugin)
   - [Tools](#tools-veiltool)
   - [Policy hooks](#policy-hooks-veilon_policy)
   - [Prompt hooks](#prompt-hooks-veilon_prompt)
   - [MCP bridge plugins](#mcp-bridge-plugins-veilmcp)
6. [The `veil.*` API reference](#6-the-veil-api-reference)
7. [The sandbox & security model](#7-the-sandbox--security-model)
8. [How it reaches the whole ecosystem](#8-how-it-reaches-the-whole-ecosystem)
9. [Managing plugins & themes (endpoints, CLI, reload)](#9-managing-plugins--themes)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Where things live

Everything lives under your veil **data directory** (the folder that holds `u1/`, your chats, etc.). Two
subfolders matter:

```
<data>/
├── themes/                 ← one *.lua file per theme
│   ├── dark.lua            (shipped; seeded on first run — edit freely)
│   ├── light.lua           (shipped)
│   ├── matrix.lua          (shipped)
│   ├── themes.json         (auto-generated cache — do not edit)
│   └── ocean.lua           ← your custom theme
└── plugins/                ← one folder per plugin
    └── greeter/
        └── plugin.lua      ← the plugin manifest (required)
```

- The three shipped themes are **seeded as real files** on first run. They are the source of truth from
  then on — edit them and your edits win. Delete one and the compiled-in copy is used as a fallback.
- A plugin is any folder under `plugins/` that contains a `plugin.lua`. The folder name is only a label;
  the plugin's real id comes from `veil.plugin{ name = ... }` inside the file.
- To find these folders from the desktop app: **File → Themes folder** (opens `<data>/themes`).

Changes are picked up when the server (re)starts, or immediately via a reload — see
[§9](#9-managing-plugins--themes).

---

## 2. Quickstart: a theme in 60 seconds

Copy `themes/dark.lua` to `themes/ocean.lua`, give it a fresh `id`, tweak some colors:

```lua
-- <data>/themes/ocean.lua
return {
  id      = "ocean",      -- unique slug: [a-z0-9_-], max 24 chars
  name    = "Ocean",      -- display name
  dark    = true,         -- dark ground? (web derives its base light/dark from this)
  mono_ui = false,        -- true = render the WHOLE UI in the mono/code font (see matrix.lua)
  colors  = {             -- any SUBSET; omitted slots inherit the dark/light base
    bg   = "#0b1e2d",
    fg   = "#cfe8ff",
    blue = "#4bb3fd",     -- the PRIMARY accent (buttons, active tab, focus)
    green= "#3fd0a0",
    red  = "#ff6b81",
  },
}
```

Restart the app (or reload) and pick it from the theme selector. That's it — it now appears in the
desktop app's titlebar theme cycle, the web app's theme switcher, and `veil themes` on the CLI.

---

## 3. Quickstart: a plugin in 2 minutes

Create `plugins/greeter/plugin.lua`:

```lua
-- <data>/plugins/greeter/plugin.lua

-- 1) declare the plugin (required — do this first)
veil.plugin{ name = "greeter", version = "1.0", description = "adds a hello tool" }

-- 2) register a tool the AI can call. It shows up to the model as `plug_greeter_hello`.
veil.tool{
  name = "hello",
  description = "Return a friendly greeting for a name.",
  params = {
    who = { type = "string", description = "who to greet", required = true },
  },
  handler = function(args)
    return "Hello, " .. (args.who or "friend") .. "!"
  end,
}
```

Reload (`veil plugins reload`, or restart). The AI can now call your tool during any chat turn. Confirm it
loaded:

```bash
veil plugins
```

```
NAME       VERSION  STATE  KIND    TOOLS  ERROR
greeter    1.0      ok     script  1
```

---

## 4. Themes in depth

A theme is a Lua file that **returns a table**. Fields:

| field     | type    | required | meaning                                                                 |
|-----------|---------|----------|-------------------------------------------------------------------------|
| `id`      | string  | **yes**  | Unique slug `[a-z0-9_-]`, ≤24 chars. This is what gets persisted.        |
| `name`    | string  | no       | Display name (defaults to `id`).                                        |
| `dark`    | boolean | no       | Dark ground? Default `true`. The web app derives its base scheme + `color-scheme` from this. Omitted color slots inherit the **dark** or **light** builtin base accordingly. |
| `mono_ui` | boolean | no       | Default `false`. When `true`, the **entire UI** renders in the mono/code font — desk and web both. This is what makes the shipped `matrix` theme feel like a terminal. |
| `colors`  | table   | no       | Any subset of the 16 palette slots below, each a `"#rrggbb"` string.     |

### The 16 palette slots

Order and names are **frozen** — the desktop app, the web CSS variables, and the JSON API all key off
these exact names:

| slot      | role                                   | slot      | role                          |
|-----------|----------------------------------------|-----------|-------------------------------|
| `bg`      | panel ground                           | `blue`    | **primary accent** (buttons, active tab, focus ring) |
| `bg_dark` | chrome / titlebar                      | `cyan`    | secondary accent              |
| `bg_hl`   | hover highlight                        | `green`   | success / online              |
| `bg_sel`  | selection                              | `magenta` | brand mark                    |
| `fg`      | main text                              | `orange`  | warnings                      |
| `fg_dim`  | secondary text                         | `red`     | errors / danger (keep it legible — it is the alarm color) |
| `comment` | muted text                             | `yellow`  | attention                     |
| `border`  | hairlines                              | `teal`    | accent                        |

**Design guidance:** even in a stylized theme, keep `red` alarming and `orange` warm — they carry meaning
(a failed build, a destructive action). `blue` is the workhorse accent; make it readable on `bg`. You only
need to override the slots you care about; the rest inherit a sensible base.

### How a theme flows through the ecosystem

1. You drop `ocean.lua` in `<data>/themes/`.
2. The server evaluates every `*.lua` theme in its sandbox and writes a compiled cache, `themes.json`.
3. The **web app** fetches `GET /api/v1/themes` and applies your colors as CSS custom properties, cycling
   through every theme.
4. The **desktop app** reads `themes.json` directly (it shares the machine) and cycles every theme from the
   titlebar — no server round-trip needed, works offline.
5. The **CLI** shows them via `veil themes`.

---

## 5. Plugins in depth

A plugin is a folder with a `plugin.lua` manifest. The manifest runs **once at load** in a sandboxed Lua
state; it calls `veil.*` functions to register what the plugin provides. After load, the plugin's Lua state
stays alive to serve its hooks and tools.

A plugin can provide any combination of:

- **Tools** — new functions the AI can call (`veil.tool` / `veil.mcp`).
- **A policy hook** — vet every tool call before it runs (`veil.on_policy`).
- **A prompt hook** — inject system-prompt text into every turn (`veil.on_prompt`).

### The manifest: `veil.plugin`

Call this **first**. It names the plugin (the name becomes the prefix of every tool: `plug_<name>_<tool>`).

```lua
veil.plugin{
  name        = "greeter",      -- required, [a-z0-9_], ≤24 chars, UNIQUE across plugins
  version     = "1.0",          -- optional, free-form
  description = "what it does",  -- optional, shown in `veil plugins`
}
```

### Tools: `veil.tool`

Registers a model-callable tool. The AI sees it as `plug_<plugin>_<tool>` alongside the built-ins.

```lua
veil.tool{
  name = "wordcount",                        -- [a-z0-9_], ≤24 chars
  description = "Count words in some text.",  -- the model reads this to decide when to call it
  params = {                                 -- becomes the JSON-schema the model fills in
    text  = { type = "string",  description = "the text to count", required = true },
    unique= { type = "boolean", description = "count distinct words only" },
  },
  handler = function(args)
    -- args is a Lua table of the model's arguments
    local n = 0
    for _ in tostring(args.text or ""):gmatch("%S+") do n = n + 1 end
    return { ok = true, words = n }           -- see "Return values" below
  end,
}
```

**Parameters.** Two ways to declare them:
- `params = { name = { type=, description=, required= } }` — the friendly form (shown above). `type` is any
  JSON-schema type (`string`, `number`, `integer`, `boolean`, `object`, `array`).
- `params_json = [[ {"type":"object","properties":{...},"required":[...]} ]]` — supply a raw JSON-schema
  string if you need full control. It is validated at load; invalid JSON fails the plugin.

**Return values.** Your handler can return:
- a **string** — used verbatim as the tool result.
- a **table** — serialized to JSON automatically.
- **nil** — becomes `{"ok":true}`.

**Errors.** If your handler calls `error("...")`, veil catches it and returns a clean
`(plugin greeter tool wordcount error: ...)` string to the model — a buggy tool never crashes the app.

### Policy hooks: `veil.on_policy`

A policy hook sees **every tool call** (built-in, recipe, or plugin) before it runs and can **deny** it.
Use it to enforce guardrails — block a tool, restrict it to admins, require an argument shape, log usage.

```lua
veil.on_policy(function(ctx)
  -- ctx = { uid=<number>, admin=<bool>, conv=<string>, tool=<string>, args_json=<string> }

  -- Example: never let a non-admin run host_command
  if ctx.tool == "host_command" and not ctx.admin then
    return { allow = false, reason = "host commands are admin-only here" }
  end

  -- Example: block a specific plugin tool during a particular conversation
  if ctx.tool == "plug_deployer_ship" and ctx.conv == "sandbox" then
    return false   -- a bare false denies with a generic reason
  end

  return true      -- allow (nil also means allow)
end)
```

**Verdict shape:**
- `true` or `nil` → allow.
- `false` → deny (generic reason).
- `{ allow = false, reason = "..." }` → deny, and the reason is shown to the model.

**Rules of the road:**
- The **first** plugin to deny wins.
- If your hook throws an error, it **fails open** (the call proceeds) and the error is logged — a broken
  policy plugin cannot brick tool use. Write defensively if you mean to block.
- `args_json` is the raw arguments string; parse it with `veil.json_decode(ctx.args_json)` if you need to
  inspect specific fields.

### Prompt hooks: `veil.on_prompt`

A prompt hook returns extra **system-prompt text** for a turn — a house style, a compliance reminder,
project context, anything you want the model to always see.

```lua
veil.on_prompt(function(ctx)
  -- ctx = { uid=<number>, admin=<bool>, conv=<string> }
  return "House style: be concise, cite sources, and never use emoji."
end)
```

Return a string (or `nil`/empty to add nothing). The text is injected on the per-turn channel, so it
**never breaks provider prompt caching**. Keep it short — it rides on every inference of the turn (there is
a ~1.2 KB per-plugin clip).

### MCP bridge plugins: `veil.mcp`

Bridge an external **MCP server** (Model Context Protocol) so all of its tools become veil tools. veil
spawns the server over stdio per call, does the JSON-RPC handshake, and advertises each of its tools as
`plug_<plugin>_<toolname>`.

```lua
-- plugins/filesystem/plugin.lua
veil.plugin{ name = "fsmcp", description = "bridges an MCP filesystem server" }

veil.mcp{
  command   = { "npx", "-y", "@modelcontextprotocol/server-filesystem", "/path/to/allow" },
  env       = { SOME_TOKEN = "..." },   -- optional extra environment
  timeout_s = 20,                        -- optional (default 20, max 300)
}
```

At load, veil runs the server's `tools/list` once and registers every tool it reports. When the model
calls one, veil spawns the server, runs `tools/call`, and returns the result. A hung server is killed by a
watchdog. If the server can't be listed at load (not installed, bad command), the plugin loads as
`failed` with the error — it never blocks the rest.

> An MCP plugin and a script plugin are mutually complementary in one file is possible, but the common case
> is one `veil.mcp{}` **or** a set of `veil.tool{}` per plugin.

---

## 6. The `veil.*` API reference

Everything below is available inside `plugin.lua` and your handlers. There is **no** `require` of standard
Lua libraries beyond the whitelist (see [§7](#7-the-sandbox--security-model)); the `veil` table is your
interface to the host.

| function | when | description |
|----------|------|-------------|
| `veil.plugin{ name=, version=, description= }` | load only | Declare the plugin. Call first. |
| `veil.tool{ name=, description=, params=/params_json=, handler= }` | load only | Register a model-callable tool. |
| `veil.on_policy(fn)` | load only | Register the policy hook `fn(ctx) -> verdict`. |
| `veil.on_prompt(fn)` | load only | Register the prompt hook `fn(ctx) -> string`. |
| `veil.mcp{ command={...}, env={...}, timeout_s= }` | load only | Bridge an external MCP server's tools. |
| `veil.log(...)` | anytime | Log a line to the server log (also installed as global `print`). |
| `veil.json_decode(s) -> table|nil, err` | anytime | Parse a JSON string into a Lua table. |
| `veil.json_encode(v) -> string|nil` | anytime | Serialize a Lua value to JSON. |
| `veil.read_file(rel) -> string|nil, err` | anytime | Read a file **inside your plugin folder** (relative path only, no `..`). Good for shipping data alongside your plugin. |

You can also `require("submodule")` **within your own plugin folder** — a `require("util")` loads
`<your plugin>/util.lua` (dotted names map to subfolders). It is scoped strictly to your folder.

**The `ctx` tables:**
- policy: `{ uid, admin, conv, tool, args_json }`
- prompt: `{ uid, admin, conv }`
- tool handler: your declared `args`, as a Lua table.

---

## 7. The sandbox & security model

Plugins are **untrusted code by default**. They run in an isolated Lua 5.4 state with hard limits, so a
buggy or hostile plugin cannot damage the host, hang a chat, or exfiltrate data on its own.

**What a plugin CAN do:**
- Pure computation: `string`, `table`, `math`, `utf8`, `coroutine`, and the clock/date halves of `os`
  (`os.time`, `os.date`, `os.clock`, `os.difftime`).
- Register tools/hooks and return data from them.
- Read files inside its own folder (`veil.read_file`, `require`).
- Reach the outside world **only** through tools you route deliberately — e.g. a `veil.mcp` bridge, or by
  returning a request for a built-in tool. There is no raw socket or process API.

**What a plugin CANNOT do:**
- No `io` library, no `os.execute`/`os.getenv`/`os.remove`/`os.exit`, no `debug` library, no `package`/C
  loader, no `dofile`/`loadfile`.
- `load()` accepts **text chunks only** — precompiled bytecode is rejected (a classic sandbox escape).
- No filesystem access outside the plugin's own folder.

**Resource limits (per host→plugin call):**
- **Instruction budget** — a runaway loop (`while true do end`) is force-stopped, not allowed to wedge a
  chat thread.
- **Memory cap** — a string/table bomb hits an allocation ceiling and errors instead of OOM-ing the host.
- **Time-bounded** for MCP bridges via a kill-watchdog on the child process.

**Failure is contained:**
- A plugin that throws at load becomes `state = failed` with its error recorded; other plugins are
  unaffected.
- A hook that errors at runtime **fails open** (policy) or is **skipped** (prompt), and increments a
  `hook_errors` counter you can see in `veil plugins`.

**Trust boundaries that still apply:**
- Plugin **tools** are advertised to the model like any tool, and they run through the **same policy gate**
  — including policy hooks from *other* plugins. A plugin tool does not bypass veil's own capability gates
  (a sandboxed, non-admin user still can't reach admin-only built-ins through a plugin).
- Because a plugin is code you install, treat third-party `plugin.lua` files the way you'd treat any script
  you run: read them first. The sandbox limits blast radius; it is not a licence to run unknown code
  blindly.

---

## 8. How it reaches the whole ecosystem

You author **once**; it shows up **everywhere**, because the server is the single source of truth:

```
          <data>/themes/*.lua          <data>/plugins/*/plugin.lua
                  │                              │
                  ▼                              ▼
         ┌─────────────────────────────────────────────┐
         │   server: evaluate in the Lua sandbox        │
         │   → theme registry + plugin registry         │
         │   → writes themes/themes.json cache          │
         └─────────────────────────────────────────────┘
            │                    │                   │
   GET /api/v1/themes    reads themes.json    hooks into every chat turn
   GET /api/v1/plugins   (shared filesystem)  (policy + prompt + tools)
            │                    │                   │
         ┌──────┐           ┌────────┐          ┌─────────┐
         │ web  │           │  desk  │          │   AI    │
         │ app  │           │  app   │          │  turns  │
         └──────┘           └────────┘          └─────────┘
                    │
                 ┌─────┐
                 │ CLI │  veil themes / veil plugins
                 └─────┘
```

- **Themes** reach web (CSS variables via the API), desk (the `themes.json` cache), and CLI (`veil themes`).
- **Plugins** hook the AI's turns wherever they run — a desktop chat, a web chat, a scheduled task, a
  swarm — because the hooks live in the server engine, not any one client.

---

## 9. Managing plugins & themes

### Endpoints

| method & path | auth | purpose |
|---------------|------|---------|
| `GET /api/v1/themes` | public | List all themes with their colors (the web app paints its login screen from this). |
| `GET /api/v1/plugins` | user | List loaded plugins, their tools, state, and any load errors. |
| `POST /api/v1/plugins/reload` | admin | Rescan `<data>/plugins` + `<data>/themes` and hot-swap the live registry — no restart. |

### CLI

```bash
veil themes                 # table of every theme
veil themes ocean           # the full 16-color palette of one theme
veil themes --json          # raw JSON

veil plugins                # table of loaded plugins (name, state, kind, #tools, errors)
veil plugins reload         # admin: rescan + hot-swap
veil plugins --json         # raw JSON
```

### Reloading

After editing a plugin or theme, either restart the server or run `veil plugins reload` (admin). The reload
re-evaluates every file and atomically swaps the live registry — in-flight chat turns keep using the
version they started with, so a reload is always safe.

### Disabling a plugin without deleting it

Drop an empty `.disabled` file in the plugin's folder:

```
plugins/greeter/.disabled
```

It will be skipped entirely on the next load.

---

## 10. Troubleshooting

**My theme doesn't appear.**
- Check the filename ends in `.lua` and the file `return`s a table with a valid `id` (`[a-z0-9_-]`, ≤24
  chars). Run `veil themes` — if it's missing, the server skipped it; the server log names the reason.
- Restart or `veil plugins reload`.

**My plugin shows `state = failed`.**
- Run `veil plugins` (or `GET /api/v1/plugins`) — the `ERROR` column has the exact message (a Lua syntax
  error, a missing `veil.plugin{ name = }`, an invalid `params_json`, or an MCP server that wouldn't list).
- The server log has the same line at load time.

**My tool never gets called.**
- Make the `description` specific — the model decides whether to call a tool from its description. Vague
  descriptions get ignored.
- Confirm the advertised name: it's `plug_<plugin>_<tool>`, not just `<tool>`.

**My policy hook isn't blocking.**
- A hook that errors **fails open**. Guard against `nil` fields and wrap risky logic; test with a simple
  `return false` first to confirm it fires at all.
- Remember the **first** denying plugin wins; another plugin may be allowing it.

**A loop or big allocation errors out.**
- That's the sandbox budget doing its job. Do heavy work incrementally or move it behind an MCP bridge /
  external tool rather than computing it inside a hook.

**`hook_errors` is climbing.**
- Your policy/prompt hook is throwing on some inputs. Check the server log for the traceback and add
  guards.

---

*veil themes and plugins are just files — copy an example, change a few lines, reload. Start with a theme,
then a one-tool plugin, and grow from there.*
