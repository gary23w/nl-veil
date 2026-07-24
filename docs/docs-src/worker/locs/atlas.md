# atlas

**File:** `src/worker/locs/atlas.zig`  
**Module:** `worker/locs`  
**Description:** The SOURCE ATLAS — curated, compiled-in seed locations for knowledge domains: documentation roots and nl-rag pack URLs, routed to by word-bounded tag matching against goal/gap text.

---

## Purpose Summary

Not geospatial: "atlas" here is a compiled table of where to READ about a domain. Each entry names a knowledge domain (python, rust, http-rest, gdb-debugging, …) with word-bounded match tags, canonical seed URLs (doc roots, static/curl-friendly only), a kind, a suggested crawl depth, a trust prior, and — for covered domains — the URL of an nl-rag PACK index (pre-normalized markdown mirrors of the docs). Free text from a goal or knowledge-gap report is matched against the tags, and the top domains are rendered into a "CANONICAL SOURCES" block appended to a research directive, so a mind fetches authoritative docs first and falls back to search.

## Key Exports

- `Kind` — `reference`, `tutorial`, `spec`, `cookbook`, `index`
- `Loc` — one domain: `name`, `tags` (word-bounded match keys, multi-word allowed), `seeds` (doc-root URLs), `kind`, `depth`, `trust` (ranking prior only — learned application-trust decides what survives), `pack` (nl-rag INDEX url, fetch-first when set)
- `ATLAS` — the compiled-in table: the original hand-curated base block (listed first so ties resolve toward it) plus expansion waves, every seed live-curl-verified (200 with real static HTML) and tag-safety audited
- `setExtension(ext)` / `extension()` — the runtime extension: entries built from a local knowledge-corpus manifest (ragmirror.zig) covering the thousands of pack domains the compiled table doesn't; set once at process start, read-only afterwards
- `match(text, out)` — rank entries against free text: score = word-bounded tag hits × trust; pure and allocation-free, callable from hot paths; extension entries compete through a bounded top-K and compiled entries win ties
- `sourcesBlock(gpa, text, max_locs)` — the "CANONICAL SOURCES" directive block for the top matched domains (PACK url first when present, then seeds); `""` when nothing matches so the directive reads exactly as before

## Dependencies

- `std` only. Extension entries are supplied by `worker/ragmirror` at startup via `setExtension`.

## Usage Context

Research routing: `sourcesBlock` output is appended to a mind's research directive when its goal/gap text matches a domain, steering `web_fetch`/`deep_crawl` at curated docs before generic search. `ragmirror.zig` installs the runtime extension from the local pack manifest (and its tests route through `atlas.match`).

## Notable Implementation Details

- Word-bounded matching is load-bearing: `wordHit` is case-insensitive with trailing-'s' plural tolerance, and "rust" must never fire inside "trust" (tested). The curation rules forbid tags that are common English words ("golang" not "go") and require common dev words to be anchored to their domain ("gdb debugging", not "debugging") so unrelated prose can't false-route.
- nl-rag packs (github.com/gary23w/nl-rag) mirror curated doc pages as pre-normalized, frontmattered markdown split into fetch-sized parts — better input for a small model than the raw site; pack bodies ride the existing 7-day fetch cache. Seeds stay listed: the pack is a fast mirror, not a replacement, and freshness-critical topics should still hit the origin.
- `match` uses a stack insertion sort over the compiled hits and a fixed top-K (8) sorted-insert for the extension, then merges best-first — zero allocation even with thousands of extension entries; the compiled table wins ties so hand-tuned routing never loses to a generated entry.
- Tests pin domain routing across the expansion waves, plural tolerance, silent behavior on generic prose, and the audit that de-fanged common-word tags.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
