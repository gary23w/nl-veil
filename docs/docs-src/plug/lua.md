# lua

**File:** `src/plug/lua.zig`  
**Module:** `plug`  
**Description:** The embedded Lua 5.4 runtime every veil extension point runs on — raw bindings to the vendored Lua, the lua.h macros as Zig functions, and a sandboxed Vm.

---

## Purpose Summary

One file, three layers. Layer 1 is `c`: hand-written extern bindings to the vendored Lua (vendor/lua, 5.4.8) — no @cImport, because the C API is small and stable and explicit externs keep the ABI visible and the build translate-c-free. Layer 2 re-implements the macros lua.h doesn't export as functions (pop/tostring/pcall/…) so call sites read like the Lua manual. Layer 3 is `Vm`, a SANDBOXED state: whitelisted stdlib (no io, no debug, no os.execute), text-only chunk loading (bytecode is a sandbox escape), a plugin-dir-scoped `require`, an instruction budget so a `while true do end` cannot wedge a chat thread, and a byte-capped allocator so a string bomb cannot OOM the host.

## Key Exports

- `c` — the extern C API (state, stack, table, pcall, load, ref, and the whitelisted `luaopen_*` functions)
- Constants — status codes (`OK`…`ERRERR`), type tags (`TNIL`…`TTHREAD`), `REGISTRYINDEX`, `NOREF`, `MASKCOUNT`, etc.
- Macro twins — `pop`, `pushCFn`, `toString`, `pushSlice`, `pcall`, `remove`, `insert`, `upvalueIndex`
- `Vm` / `VmOptions` — `init`/`deinit`, `openSandboxedLibs`, `setRoot` (scopes require + veil.read_file), `armBudget`, `runBuffer` (text-only compile+run with traceback), `callTop`, `lastError`, and the `fieldStringDup`/`fieldBool`/`fieldInt` table readers
- `readSmallFile` — bounded whole-file read helper
- `pushJson` / `luaToJson` — the JSON↔Lua bridge (arrays for 1..n integer-keyed tables; depth-capped at 24 so a cyclic table can't recurse forever)

## Dependencies

- `std` + `builtin` and the vendored Lua C library resolved at link time (extern fns) — no app modules

## Usage Context

`plug/plugins.zig` runs each plugin's manifest and hooks in one long-lived Vm per plugin; `plug/theme.zig` uses a throwaway Vm per theme file. Defaults: 64 MiB heap cap, ~50M-instruction budget per host→Lua entry.

## Notable Implementation Details

- A Vm is NOT thread-safe: owners serialize entry with a mutex (plugin registry) or use a throwaway per load (themes). CFns called back from Lua must not hold defers across `lua_error` — Lua unwinds with longjmp and Zig defers in that frame will not run.
- `armBudget` must be re-armed before EVERY host→Lua entry: the counter carries across pcalls inside one state, so many small calls would eventually trip it. The budget hook unhooks itself before raising so the unwind can't re-enter.
- `openSandboxedLibs` opens base/string/table/math/utf8/coroutine/os, then prunes os to the pure clock/date functions (execute, exit, getenv, remove, rename, setlocale, tmpname removed) and deletes dofile/loadfile/collectgarbage; `load` is replaced with a string-chunk, TEXT-mode-only version.
- The scoped `require` resolves dotted identifiers only (no separators, no traversal) strictly inside `root_dir`, text-mode loads, and caches like stock require.
- The capped allocator honors the Lua manual's rule that osize encodes an object KIND when ptr is null; over budget returns null so Lua raises ERRMEM.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
