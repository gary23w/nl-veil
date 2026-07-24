# catalog

**File:** `desk/src/catalog.zig`  
**Module:** `desk`  
**Description:** The desk's view of the model catalog + the deploy option sets — the provider/model list is re-exported from `modelcfg` (comptime-parsed models.yaml, the same source the server reads), and only the desk-specific pieces live here.

---

## Purpose Summary

This file no longer hand-writes a provider/model table. `modelcfg` comptime-parses the repo-root `models.yaml` — the SAME source the server reads — and this module re-exports its types and data so every desk menu (chat Settings, Swarm deploy, Tasks model override) and the server stay in lockstep: edit models.yaml, rebuild, everything updates. What remains desk-specific is `resolveBase()` (the `{account}` substitution the desk performs before sending a base_url) and the deploy option sets (styles / stacks / modes / minutes), which are workflow knobs, not models.

## Key Exports

- `Model`, `Provider` — re-exports of the `modelcfg` types
- `Tier`, `ModelSense`, `senseModel` — model capacity sensing (params/ctx/tier from yaml metadata or the model id); the desk keys its prompt variant + per-section budgets off this (see chat.zig `budgetFor`)
- `providers` — THE provider list, a comptime slice from models.yaml; array-style access (`providers[i]`, `.len`, `for`) works exactly as the old in-file array did
- `defaults` — the local + Cloudflare model defaults from models.yaml, for the "no model chosen" fallbacks
- `resolveBase(p, account, out)` — substitute the account id into a `{account}`-templated base_url (Cloudflare Workers AI) using the caller's buffer; with no account id (or when the result won't fit) returns the `"cloudflare"` sentinel so the server falls back to its own configured Workers AI credentials; non-templated URLs pass through untouched
- `styles` (`auto`/`build`/`build_use`/`investigate`/`debate`), `stacks` (`general`/`static`/`node`), `modes` (`continuous`/`checkpoint`/`refine`/`cast`), `minutes` / `minutes_lbl` (0 = "until stopped")

## Dependencies

- `modelcfg` — the shared comptime models.yaml module (the catalog's single source of truth)
- `log.zig` — trace logging in `resolveBase`

## Usage Context

`main.zig` drives every provider/model dropdown and the Deploy form off `providers`/`styles`/`modes`/`minutes`, calls `resolveBase` to produce the base_url actually sent, and falls back to `defaults.local_model`; `chat.zig` selects prompt tiers via `senseModel`. `store.zig` persists BYOK selections as indices into `providers`, so the yaml's provider order is part of the persisted-settings contract.

## Notable Implementation Details

- The catalog is compiled in, but from models.yaml rather than a hand-maintained array — the old in-file provider table is gone, and desk/server drift is structurally impossible while both build from the same yaml.
- `resolveBase` never allocates: it memcpy's pre + trimmed account + post into the caller-supplied `out` and returns a slice of it. Its two fallbacks both return the literal `"cloudflare"` — no account id, or the substituted URL would overflow `out` — meaning "let the server use its included/env Workers AI creds".
- `"cast"` is documented in-file as the fast scatter-gather mode: the lead decomposes the goal, each mind runs ONE moment on its slice (~1–2 min), and the result is synthesized — vs `"continuous"`, which loops for the whole budget.

---

*Case file grounded in the module's `//!` header and public API.*
