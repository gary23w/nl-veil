# ragmirror

**File:** `src/worker/ragmirror.zig`  
**Module:** `worker`  
**Description:** Local knowledge-pack mirror — serve nl-rag pack urls from a local tree instead of the network, so the entire fetch surface (engine pack prefetch, scout web_fetch of INDEX/pages, deep crawls) reads from disk transparently: same urls, same callers, zero network.

---

## Purpose Summary

The knowledge corpus (github.com/gary23w/nl-rag) is fetchable per-page over raw.githubusercontent — fine online, a dead end for the offline appliance and a tax on every cold fetch. When a local copy exists (the git clone, a vendored `vendor/nl-rag`, or a synced `<data>/_rag`), this module maps any pack url onto that tree. It also carries `atlas.json`, the corpus's own manifest, from which the compiled-in source atlas is extended at runtime: the compiled atlas names ~600 domains; the corpus has thousands.

## Key Exports

- `RAW_BASE` — the corpus url prefix a mirrorable url must carry
- `setRoot(p)` / `root()` / `active()` — the adopted mirror root (set-once at process start, read-only afterwards — no locking on the hot path)
- `resolve(io, gpa, url, limit)` — map a corpus url onto the local tree and read it; null = not a corpus url, no mirror, or not mirrored (caller falls through to its normal network path)
- `buildExtension(gpa, atlas_raw, include_auto)` — runtime atlas entries for every pack the compiled atlas does NOT already cover: its own tags plus tags derived from the domain name, so a goal can hit a pack by name
- `SyncTier` (`atlas` | `facts` | `full`) + `SyncStats` + `syncFrom(gpa, io, from, dest, tier, include_auto)` — copy a corpus tree into `dest` so the app carries its knowledge base locally; idempotent overwrite
- `freeExtension(gpa, ext)` — test teardown (extension allocations otherwise live for the process)
- `initAt(gpa, io, environ, data_dir)` — one-call startup wiring: detect a mirror, adopt it as the resolver root, extend the atlas from its manifest; call ONCE per process before any concurrent fetch path runs

## Dependencies

- `worker/locs/atlas.zig` — `Loc`, the compiled `ATLAS` table (dedup source), `setExtension`, and `match` (the tests prove extension entries are matchable)
- `std` — filesystem reads + JSON manifest parse

## Usage Context

`main.zig` and `worker/run.zig` wire `initAt` at startup; `cli.zig` drives `syncFrom` (`<data>/_rag` is the `veil rag sync` destination per the header); `worker/tools.zig` consults `resolve` on the fetch path.

## Notable Implementation Details

- Root resolution order (first tree carrying an `atlas.json` wins): `NL_RAG_DIR` explicit override → `<data>/_rag` → `vendor/nl-rag`.
- A url is attacker-adjacent input (models emit them): `resolve` refuses `..` traversal so a url can never climb out of the mirror; `syncFrom` applies the same `..` / path-separator screening to manifest names.
- Machine-grown (`origin: auto`) packs are excluded from both the atlas extension and sync unless explicitly included (`NL_RAG_AUTO=1` / `include_auto`) — that half of the corpus drifted off-topic and would pollute goal routing.
- Name-derived tags are gated by a generic-token list ("advanced", "systems", "programming", …) so common name fragments can't false-route goals; the pack's own curated tags stay authoritative. Extension entries carry trust 0.7 — below every hand-tuned prior, so the compiled atlas wins ties — and packs the compiled atlas already routes are skipped to avoid double-listing.
- Sync tiers: `atlas` = the manifest alone (routing only); `facts` = + each pack's INDEX.md and pack.facts (the retrieval floor); `full` = + every pack page.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
