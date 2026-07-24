# deps

**File:** `src/worker/deps.zig`  
**Module:** `worker`  
**Description:** Dependency probe — DETECT + INSTRUCT ONLY: answers precisely whether an external binary (python, node, npm, curl, git, a Chromium-family browser) is present, and if not, exactly what the user should type to fix it.

---

## Purpose Summary

The app spawns external binaries all over the toolbelt, and a missing one used to surface as a flat "X failed to run" or a silent empty string — for curl it even masqueraded as "internet down". This module answers one question safely: is dependency `<name>` present, and if not, what should the user do. It never installs, downloads, or mutates anything; a missing binary is a NORMAL answer (present=false plus a hint), never an error. The hint strings are the entire value of the feature — each names the winget id, the vendor download, and the `NL_<DEP>_BIN` escape hatch.

## Key Exports

- `Dep { name, present, version, hint }` — one probe result; `name` is a static literal, `version`/`hint` are gpa-owned
- `standard` — the fixed set surfaced on the health page (`python, node, npm, curl, git, browser`), in stable display order
- `isSpawnMissing(err)` — true only when a `std.process.run` error means the binary itself could not be started (not on PATH, bad override, not a runnable image) — vs a program that RAN and then failed
- `probe(gpa, io, env, name)` — probe one dependency: env override first, then PATH resolution, then the remediation hint
- `probeAll(gpa, io, env)` — probe the whole `standard` set for the health surface
- `hint(gpa, name)` — the remediation string WITHOUT probing, for a spawn site that already caught a spawn-missing error

## Dependencies

- `worker/browser/launch.zig` — the browser probe reuses `launch.discover()` so there is exactly one place a browser is found
- `std` — `std.process.run` for the PATH locator and `--version` reads

## Usage Context

Imported by `main.zig`, `worker/run.zig`, and `worker/tools.zig`. `probeAll` feeds the health page's dependency list; `isSpawnMissing` + `hint` are the pattern for call sites that already tried to spawn a binary and only need the actionable message.

## Notable Implementation Details

- Resolution order in `probe`: an `NL_<DEP>_BIN` override pointing at a real file wins; then `where` (Windows) / `which` (POSIX) resolves the binary on PATH without executing it; absence yields the spec's remedy text.
- If the locator itself can't spawn (a stripped container with no `which`), a direct `<bin> --version` fallback decides — so a missing locator never masquerades as a missing dependency.
- `isSpawnMissing` draws the exact line of the feature: only FileNotFound/NotDir/IsDir/InvalidExe/InvalidName/AccessDenied/PermissionDenied earn a hint; StreamTooLong, timeouts, OOM, and resource limits keep the caller's "it ran and something went wrong" behaviour.
- Version reads are best-effort and bounded (5s timeout, first non-blank line, clipped to 120 bytes, stderr fallback for tools like older python) — they never fail the probe.
- The browser probe never runs `<browser> --version`: on Windows `msedge.exe --version` can OPEN A BROWSER WINDOW, so presence comes from `discover()`'s path check and the executable's basename is reported as the identity.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
