# Extending veil — themes & plugins

veil is built to be extended without a rebuild or a fork. You add two kinds of thing, both as small files
you drop into your data directory:

- **Themes** — re-skin the whole product. A theme is a tiny Lua file returning a color table.
- **Plugins** — add new tools the AI can call, policies that gate what runs, and prompt text that shapes
  every turn. A plugin is a Lua manifest evaluated in a locked-down sandbox.

Whatever you author works across the **entire ecosystem** — the desktop app, the web app, and the CLI —
because the server is the single source of truth and every client reads from it.

> The complete, copy-paste authoring reference lives in **`PLUGINS.md`** at the repo root. These pages are
> the guided tour: [Authoring a theme](#doc=guide/themes) · [Writing a plugin](#doc=guide/plugins).

## Where things live

Everything is under your veil **data directory** (the folder with `u1/`, your chats, etc.):

```
<data>/
├── themes/                 one *.lua per theme (dark/light/matrix are seeded on first run)
│   └── themes.json         auto-generated cache — do not edit
└── plugins/
    └── <name>/plugin.lua   one folder per plugin
```

From the desktop app, **File → Themes folder** opens `<data>/themes` directly.

## The flow

```
<data>/themes/*.lua   <data>/plugins/*/plugin.lua
        │                       │
        ▼                       ▼
   server evaluates every file in the Lua sandbox
        → theme registry + plugin registry
        → writes themes/themes.json
   ┌────────────┬─────────────────┬──────────────────┐
   ▼            ▼                 ▼                  ▼
 web app      desk app          CLI               AI turns
 (API)     (themes.json)   (veil themes/plugins)  (hooks)
```

- **Themes** reach the web app (as CSS variables via `GET /api/v1/themes`), the desk (via the shared
  `themes.json` cache — works offline), and the CLI (`veil themes`).
- **Plugins** hook the AI's turns wherever they run — desktop chat, web chat, a scheduled task, a swarm —
  because the hooks live in the server engine, not any one client.

## 60-second theme

Copy `themes/dark.lua` → `themes/ocean.lua`, change the `id` and a few colors:

```lua
return {
  id = "ocean", name = "Ocean", dark = true, mono_ui = false,
  colors = { bg = "#0b1e2d", fg = "#cfe8ff", blue = "#4bb3fd" },
}
```

Restart or reload; it appears in every client's theme picker. Full detail:
[Authoring a theme](#doc=guide/themes).

## 2-minute plugin

`plugins/greeter/plugin.lua`:

```lua
veil.plugin{ name = "greeter", version = "1.0", description = "adds a hello tool" }

veil.tool{
  name = "hello",
  description = "Return a friendly greeting for a name.",
  params = { who = { type = "string", description = "who to greet", required = true } },
  handler = function(args) return "Hello, " .. (args.who or "friend") .. "!" end,
}
```

`veil plugins reload` (or restart), then `veil plugins` to confirm. Full detail:
[Writing a plugin](#doc=guide/plugins).

## Managing them

| method & path | auth | purpose |
|---|---|---|
| `GET /api/v1/themes` | public | all themes + their colors |
| `GET /api/v1/plugins` | user | loaded plugins, tools, state, errors |
| `POST /api/v1/plugins/reload` | admin | rescan + hot-swap, no restart |

CLI: `veil themes`, `veil themes <id>`, `veil plugins`, `veil plugins reload`.
Disable a plugin without deleting it: drop an empty `.disabled` file in its folder.
