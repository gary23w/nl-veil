# llamaeng

**File:** `src/worker/llamaeng.zig`  
**Module:** `worker`  
**Description:** The embedded inference engine behind the built-in model — implements `builtin.Engine` over the `veil_ll_*` C facade (`src/worker/llamashim.c`), compiled only in `-Dbuiltin` builds.

---

## Purpose Summary

One model, one context, single-flight: `generate` holds the engine mutex for the whole inference, so concurrent callers queue exactly as they would on a busy local runtime. PREFIX REUSE is the piece that makes CPU chat usable: the engine keeps the token vector currently in kv memory, finds the longest common prefix with the new prompt, drops only the divergent tail and decodes the suffix — a steady-state chat turn re-evaluates only its newest messages instead of the whole conversation. Load is lazy (first request pays it) and an unloader thread returns the ~7GB working set after `NL_BUILTIN_KEEPALIVE` seconds idle. The shim exists so the library's large by-value param structs never cross the FFI line: any upstream field change is a compile error in the shim, never silent ABI corruption.

## Key Exports

- `configure` / `repoint` — point the engine at the weights store (env knobs: `NL_BUILTIN_CTX`, `NL_BUILTIN_THREADS`, `NL_BUILTIN_KEEPALIVE`)
- `engine` — the `builtin.Engine` vtable main hands to the endpoint
- `generate` / `info`

## Dependencies

- `src/worker/llamashim.c` — the scalar/pointer-only C facade (build.zig `addLlamaCpp`)
- the `llama_cpp` lazy dependency (build.zig.zon, hash-pinned) — ggml + llama, CPU backend only
- `worker/builtin.zig` — the interface types

## Usage Context

NO TESTS HERE by design: everything reachable without weights lives in builtin.zig / builtin_endpoint.zig against a mock Engine; a test block in this file would drag unresolved externs into every `zig build test`.
