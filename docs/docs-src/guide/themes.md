# Authoring a theme

A theme re-skins the whole product — desktop app, web app, and (as a palette listing) the CLI. It's a
single Lua file in `<data>/themes/` that **returns a table**.

The three shipped themes (`dark`, `light`, `matrix`) are seeded there as real files on first run. Copy one
to start; your edits become the source of truth.

## The shape

```lua
-- <data>/themes/ocean.lua
return {
  id      = "ocean",      -- REQUIRED. Unique slug [a-z0-9_-], max 24 chars. Persisted as your choice.
  name    = "Ocean",      -- Display name (defaults to id).
  dark    = true,         -- Dark ground? Default true. Drives the web base scheme + which builtin
                          --   palette fills the slots you omit.
  mono_ui = false,        -- Default false. true = render the ENTIRE UI in the mono/code font
                          --   (this is what makes `matrix` feel like a terminal).
  colors  = {             -- Any SUBSET of the 16 slots below. Omitted slots inherit the dark/light base.
    bg    = "#0b1e2d",
    fg    = "#cfe8ff",
    blue  = "#4bb3fd",
    green = "#3fd0a0",
    red   = "#ff6b81",
  },
}
```

## The 16 palette slots

The names and order are **frozen** — the desktop palette, the web CSS variables, and the JSON API all key
off these:

| slot | role | slot | role |
|---|---|---|---|
| `bg` | panel ground | `blue` | **primary accent** (buttons, active tab, focus) |
| `bg_dark` | chrome / titlebar | `cyan` | secondary accent |
| `bg_hl` | hover highlight | `green` | success / online |
| `bg_sel` | selection | `magenta` | brand mark |
| `fg` | main text | `orange` | warnings |
| `fg_dim` | secondary text | `red` | errors / danger — keep it legible |
| `comment` | muted text | `yellow` | attention |
| `border` | hairlines | `teal` | accent |

Each value is a `"#rrggbb"` hex string (the leading `#` is optional).

## Design guidance

- You only override the slots you care about. The rest inherit a coherent base (dark or light per your
  `dark` flag), so a five-line theme still looks complete.
- Keep the **semantic** colors meaningful even in a stylized theme: `red` is the alarm (a failed build, a
  destructive action), `orange` is the warning, `green` is success. Don't repaint them into decoration.
- `blue` is the workhorse accent — it colors buttons, the active tab, and the focus ring. Make sure it
  reads clearly against `bg`.
- `mono_ui = true` is a strong stylistic choice: the whole interface switches to the monospace/code face.
  Great for a console/hacker aesthetic; pair it with a dark, low-chroma palette.

## How it reaches each client

1. The server evaluates every `themes/*.lua` in its sandbox and compiles them to a `themes.json` cache.
2. **Web app** — fetches `GET /api/v1/themes` and applies your 16 colors as CSS custom properties
   (`--bg`, `--fg`, …). It cycles through every theme; `mono_ui` remaps the UI font to the mono family.
3. **Desktop app** — reads the `themes.json` cache directly (shared filesystem), so it cycles every theme
   from the titlebar even with no server connection.
4. **CLI** — `veil themes` lists them; `veil themes <id>` prints the full palette.

## Try it

```bash
# after saving ocean.lua and reloading/restarting:
veil themes            # ocean appears in the table
veil themes ocean      # see the resolved 16-color palette (inherited slots included)
```

Then pick it from the desktop titlebar or the web theme switcher. See also:
[Extending veil](#doc=guide/extensions) · [Writing a plugin](#doc=guide/plugins).
