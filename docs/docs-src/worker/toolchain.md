# toolchain

**File:** `src/worker/toolchain.zig`  
**Module:** `worker`  
**Description:** PROJECT-TOOLCHAIN FLOOR — engine-side dependency bootstrap plus tier-1 acceptance rows derived from the project's OWN manifests, closing two long-standing gaps in real multi-file builds.

---

## Purpose Summary

Gap 1, BOOTSTRAP: the swarm writes a package.json / requirements.txt / Cargo.toml / go.mod, then its own tests fail on a bare host because nothing ever ran the install step — so the engine now runs the canonical install command for each manifest the deliverable carries, once per manifest change (content-fingerprinted). Gap 2, DERIVED CHECKS: with no operator-declared VERIFY rows, a non-Python deliverable had no tier-1 gate at all — "100% coverage" with nothing ever shown to compile — so the engine adopts rows from the project's own manifest. Behavior derives from what the deliverable itself declares, never a goal taxonomy.

## Key Exports

- `manifestFingerprint(io, gpa, workdir)` — content fingerprint over every dependency manifest present (package.json/-lock, requirements.txt, Cargo.toml/.lock, go.mod/.sum); 0 = none exist; a changed fingerprint is the signal to bootstrap again (a mind added a dependency mid-run)
- `bootstrap(gpa, io, environ, workdir)` — run every applicable canonical install (`npm ci` with a lockfile OR `npm install`, never both; `pip install -r`; `cargo fetch`; `go mod download`); returns a gpa-owned human note of what ran ("" when no manifest exists)
- `deriveChecks(gpa, io, workdir)` — newline-separated tier-1 rows in the exact shape the declared-checks lane runs: `npm run build --silent` / `npm test --silent` (only scripts package.json actually declares), `cargo build --quiet`, `go build ./...`, `zig build`; "" when nothing recognizable is declared (a Python deliverable stays on the engine benchmark)

## Dependencies

- `std` + `builtin`, and `bounded.zig` — `bounded.run` through `cmd /C` on Windows and `/bin/sh -c` elsewhere.

## Usage Context

Imported by `worker/run.zig`. Per the header, bootstrap is gated by the engine on live+internet+no-egress-allowlist and the swarm manifest's `bootstrap` flag; derived rows run through the SAME declared-checks lane (240s rows, harness-vs-code split), so a missing toolchain is excluded from the denominator instead of pinning the score. The header also pins the division of labor: `deps.zig` stays a pure detect+instruct probe — everything that MUTATES a workdir lives here, explicit.

## Notable Implementation Details

- API credentials are blanked from the child environment (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `NL_BROKER_AUTH`) exactly like the declared-checks lane — an install script must never see the operator's keys.
- Each install step is bounded through `bounded.run`: one 360 s deadline for the whole step (it was a silence timer that never fired on Windows for a silent install), killed with everything it started. Its output is kept as the first and last 32 KB of each stream (`head_tail`), so a chatty install runs to its exit where a 32 KB stop killed it mid-install. A failure note carries the exit code and the last 300 chars of stderr (or stdout), and a step that never finished is reported as "did not finish" with its reason (still running at the bound, or could not be run) without stopping the other steps. Tested with a fake `npm` first on PATH printing ~200 KB on each stream: a passing one reads `ok`, a failing one's note ends on its last line.
- `deriveChecks` skips npm's default `"no test specified"` placeholder — it is not a test suite — and adopts a build row only when the script is a non-empty string.
- The fingerprint XORs a per-file Wyhash (keyed by the manifest name) so both content changes and which-manifests-exist changes move it.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
