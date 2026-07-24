# recipes

**File:** `src/worker/recipes.zig`  
**Module:** `worker`  
**Description:** The DATA half of recipe tools — parse a recipe file, validate it, render its OpenAI function schema, and substitute a call's inputs and prior step results into a step's args; a recipe is an admin-authored named sequence of steps over tools a user is ALREADY allowed to run, and it is data, never host code.

---

## Purpose Summary

This module holds NO execution loop, and that placement is deliberate: a recipe runs each step by calling tools.execute() recursively, so every step re-hits the ONE sandbox gate under the caller's OWN caps (an admin-authored `run_python` step is refused when a sandboxed grantee runs it — the whole safety property, enforced at RUN time). Putting the loop here would create an import cycle with tools.zig, so this file stays pure: bytes in, parsed/validated/rendered data out. The injection surface is `substitute()`: untrusted call inputs fill a step's args template, and every spliced value is JSON-string-escaped inside a string VALUE only, so a value carrying a quote, backslash, or newline cannot break the args JSON or inject a new argument.

## Key Exports

- `MAX_STEPS` (32), `MAX_PARAMS` (24), `MAX_NAME` (64) — belt-and-braces bounds (the real depth safety lives in tools.zig at run time)
- `Step { id, tool, args_json }` — one step; args are the COMPACT re-serialized template whose `{{…}}` tokens substitute fills
- `Param { name, ptype, desc }` — one declared input
- `Recipe` + `outputStepId()` — a parsed recipe; the returned step is the authored `output` or the last step
- `Binding { name, value }` — a resolved token (a param name or a prior step id) for substitute
- `Registry` (`deinit` / `count` / `get`) — the recipe set loaded from a directory; everything lives in one arena, `get()` pointers are arena-stable until deinit
- `LoadError` — the reject reasons (`BadJson`, `BadName`, `CollidesBuiltin`, `Duplicate`, `NoSteps`, …)
- `loadDir(gpa, io, dir, isBuiltin)` — parse every `{dir}/*.json`; a bad file is skipped with a log line, a missing dir is an empty registry
- `schemaFor(gpa, rec)` — one OpenAI function-def line, same shape every tool schema in the codebase uses; all params marked required
- `validate(gpa, rec, isBuiltin, isSandbox)` — author-time report: "ERROR:" lines block the save, "WARNING:" lines are advisory (the SECURITY is the run-time gate, not this text)
- `substitute(gpa, step_args_json, params_kv, step_results_kv)` — fill the template; params shadow same-named step results, unknown tokens splice empty, malformed `{{` is emitted literally

## Dependencies

- `std` only. `isBuiltin` / `isSandbox` arrive as function pointers precisely so tools.zig is not imported (that would re-introduce the cycle).

## Usage Context

The run loop, the sandbox gate, the recursion depth cap, and the authored-name collision guard all live in `worker/tools.zig` (the make_tool collision needs the per-caller Mem db this global, db-less loader cannot see). Also imported by `worker/chat/engine.zig`, `worker/chat/tools.zig`, `gateway/http.zig`, and `main.zig`.

## Notable Implementation Details

- Recipe names take the same shape as tool names — unique, `[a-z0-9_]` — so a recipe routes by exact match like a built-in and can never carry path/escape characters; a name that would shadow a built-in is refused at load (I1).
- `substitute` only touches string VALUES: object KEYS and non-string leaves (number/bool/null) are copied verbatim, classified by peeking past a string's closing quote for `:` — a token can never land in a structural position and produce invalid JSON.
- Escaping mirrors the codebase's llm.jstr: JSON-mandatory escapes, control chars as `\uXXXX`, invalid UTF-8 replaced with U+FFFD, so output is always well-formed. The test feeds it `he said "hi"` plus a newline and backslash and strict-parses the result.
- Reload = a fresh `loadDir()` building a NEW Registry; the owner swaps it in and deinits the old one only at a turn boundary (grants and schemas are resolved once per turn) — never deinit a Registry a live turn is still reading.
- Step args are normalized through std.json at load (validated, whitespace-stripped, stable byte layout for the scanner); a missing `args` becomes `{}`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
