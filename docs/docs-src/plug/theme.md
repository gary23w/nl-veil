# theme

**File:** `src/plug/theme.zig`  
**Module:** `plug`  
**Description:** The shared theme workspace — one canonical palette model + a Lua loader, consumed by every frontend (server `/api/v1/themes` for the web app, the desk natively, the CLI for listing).

---

## Purpose Summary

A theme is a single `*.lua` file in `<data>/themes/` that returns a table: `id` (slug, what gets persisted as "my theme"), `name`, `dark` (web picks its base scheme from this), `mono_ui` (render the whole UI in the mono/code font), and `colors` — any subset of the 16 slots; missing slots default to the dark/light base implied by `dark`. The three shipped themes (dark/light/matrix) are SEEDED into the workspace as real files on first boot; the files are the source of truth from then on (edit them, they win), and the compiled-in copies are only the fallback when a seeded file is deleted or unparseable — the app can never boot themeless.

## Key Exports

- `slot_names` / `SLOT_COUNT` — the FROZEN 16-slot palette order (bg…teal): desk theme.zig, web styles.css vars, and the JSON endpoint all key off these names
- `Theme` / `ThemeSet` — fixed-buffer theme + set (max 32) with `byId`, `slice`, and a human-readable `report` of skipped/overridden files
- `parseTheme` — parse one theme source in a throwaway sandboxed Vm (exposed for tests and checking)
- `loadDir` / `loadWorkspace` — seed missing shipped files, scan `*.lua` alphabetically, builtins pinned to the front; never fails (worst case: the three compiled-in themes + a report of why)
- `seedDir` — write the shipped theme files when absent; never overwrites (the workspace belongs to the user once seeded)
- `writeCache` — write the compiled set to `<data>/themes/themes.json` after every (re)load, so the desk can render user themes without embedding Lua
- `writeJson` — the `/api/v1/themes` array payload, also reused by the CLI
- `builtin_ids`, `idForSchemeInt` / `schemeIntForId` — the shipped trio + the legacy desk `settings.theme` u8 0/1/2 mapping, kept round-trippable forever

## Dependencies

- `lua.zig` — a throwaway sandboxed Vm per file (8 MiB / 5M-instruction caps): a theme is data, and the sandbox keeps it that way

## Usage Context

`plug/plugins.zig` loads the workspace into every registry (`loadWorkspace` + `writeCache` on each reload); the server serves `writeJson`; `cli.zig`'s `veil themes` imports `slot_names` for the palette printout.

## Notable Implementation Details

- A file with a builtin's id overrides that builtin in place (keeping its pinned position and `builtin` flag); other files upsert by id, capped at MAX_THEMES with a report note.
- Color slots parse as 6-digit hex with the `#` optional; invalid hex leaves the base value.
- `writeCache` writes RELATIVE to an open themes-dir handle — NOT via cwd()+absolute sub_path, which silently no-ops on Windows here (the same reason seedDir writes relative names into an open dir). Best-effort: a write failure is non-fatal and the desk falls back to its compiled-in builtins.
- ids are validated `[a-z0-9_-]`, 1..24 chars; `name` defaults to the id.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
