# modelcfg

**File:** `src/worker/modelcfg.zig`  
**Module:** `worker`  
**Description:** The ONE model catalog, parsed at COMPTIME from the build-embedded models.yaml — every model menu and the server's provider logic read the same list; edit models.yaml, rebuild, and the whole app updates coherently.

---

## Purpose Summary

Both binaries consume this file: the server imports it directly (the yaml rides as an anonymous import) and the desk's catalog.zig re-exports it with its own copy of the yaml registered by its build. The parse runs at comptime, so `providers` is a real comptime array and every string is a slice of the embedded bytes — static lifetime, no allocation, no init step. The second half is capacity sensing: `senseModel()` is the one shared read of "how big is this model", keying the prompt variant and per-section byte budgets off a small/mid/large tier.

## Key Exports

- `Model { id, label, params_b, ctx_k, tier_ovr }` — one model row with optional yaml capacity metadata (0/null = unspecified; the catalog never guesses)
- `Provider { key, label, base_url, needs_key, needs_account, keyless, local, models }` — one provider row
- `providers` / `defaults` (`Defaults { local_model, cf_model }`) — the catalog, parsed once at compile time
- `providerForBase(base_url)` — which provider a base URL belongs to, matched on HOST (used to look a BYOK key up in the vault when a request arrives with a blank key)
- `providerForModel(model_id)` — which provider claims a model id; null for unclaimed ids — the caller must NOT guess, since guessing wrong sends one provider's key to another's endpoint
- `isKeyless(key)` / `isLocal(key)` — the deploy-logic flags
- `Tier` (small/mid/large) + `ModelSense` + `senseModel(model_id, local_hint)` — the capacity read; returned `ctx_k` is always non-zero (tier defaults 8/32/128)

## Dependencies

- `std` only, plus `@embedFile("models.yaml")` — the yaml is registered as an anonymous import by `build.zig` (and again by `desk/build.zig` for the desk's copy of the same source file).

## Usage Context

Registered as the named module `modelcfg` in both builds. Importers: `worker/chat/service.zig`, `worker/deploy/service.zig`, `worker/run.zig`, and `desk/src/catalog.zig` (re-export for every desk model menu — chat Settings, Swarm deploy, Tasks model override).

## Notable Implementation Details

- The parser accepts a deliberate YAML SUBSET documented at the top of models.yaml: two-space indents, `- ` list items with an inline first field, bare or double-quoted scalars, true/false booleans, full-line comments. A generous `@setEvalBranchQuota(20_000_000)` covers the comptime line scan.
- THE INDEX CONTRACT (test-enforced): the desk persists a provider as a raw `byok: u8` index into `providers` and dereferences it unfiltered, so the order is append-only by necessity — removing an entry silently resolves old configs to a DIFFERENT provider. The order test fails the build the moment order changes, which is the only warning anyone gets.
- `senseModel` is signal-driven, never a per-model hardcode: yaml-stated capacity wins, else params/ctx are parsed from the id itself ("8b", "1.5b", "8x7b" MoE totals, "135m", "128k"), else the provider's `local` flag (unnamed local models assume small — never drown them), else light-variant naming ("mini"/"nano"/"flash"/… as whole bounded segments, so "minimax" never reads as "mini"), else hosted-unknown = large.
- A small context window CAPS the tier regardless of params — the budgets must fit the window; an explicit yaml `tier:` pin wins over every inference (e.g. the rotating free-model router).
- The embedded catalog itself is the test fixture — CI fails on a bad models.yaml edit.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
