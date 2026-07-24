# crawl

**File:** `src/worker/crawl.zig`  
**Module:** `worker`  
**Description:** Parse HTML, prune to the meaningful content with a density heuristic, and emit clean LLM-ready markdown with link citations ([N] + a References list) — pure string/tree algorithms, no browser and no JS rendering.

---

## Purpose Summary

The in-house HTML→markdown extractor behind the AI's web-reading tools. It never fetches anything: callers hand it raw HTML bytes plus the page URL, and it parses a tolerant tag tree, prunes boilerplate/chrome, and emits markdown where each link becomes a `[N]` citation resolved in a trailing References list. It also carries the crawl-as-search pieces (harvesting result links out of a SERP page, unwrapping engine redirects) and a BM25 chunk ranker that fits a long page to a query. Pages that need JS rendering are explicitly out of scope — that path falls back to the r.jina.ai reader elsewhere.

## Key Exports

- `Node` / `Doc` / `parse(gpa, html)` — tolerant HTML tree parse (arena-backed; `Doc.deinit` frees everything)
- `Result` — `{ markdown, title, links }`
- `extract(gpa, html, base_url)` — fetch-agnostic: raw HTML → pruned, clean markdown + decoded title + citation count
- `unwrapRedirect(gpa, url)` — decode Bing `/ck/a?…u=a1<base64>` and DuckDuckGo `/l/?uddg=` wrappers to the real destination
- `searchResults(gpa, serp_html, base_url, max)` — crawl-as-search: harvest result links from a fetched SERP as "- title\n  url\n" lines with decoded real URLs
- `chunkMarkdown(a, md, out)` — split markdown into paragraph-ish chunks on blank lines
- `fitToQuery(gpa, md, query, max_bytes)` — BM25-rank chunks against a query, re-join the winners in document order near the byte cap; empty query → document head, clipped
- `hostOf(url)` — host slice of a URL (empty when schemeless)
- `extractLinks(gpa, html, base_url, max)` — structured "## Internal links / ## External links / ## Media" sections, deduped absolute URLs

## Dependencies

- `std` only. Fetching (curl, caches, escalation) lives in `tools.zig`; this module is the parser/emitter they call.

## Usage Context

`tools.zig` routes `web_fetch` through `extract` (+ `fitToQuery` when a query is given), builds `web_search` excerpts with `extract`+`fitToQuery`, and drives the multi-engine crawl-as-search loop on `searchResults`; `run.zig` uses `fitToQuery` to window a fetched page. Per the header it is the first choice for web reading, with the jina reader + curl as fallbacks underneath.

## Notable Implementation Details

- No network, no browser, no JS — everything is a string/tree algorithm over bytes the caller fetched.
- The internal parser is fallible on purpose: a swallowed node/stack append would corrupt nesting, so OOM propagates and the public `parse()` boundary degrades instead.
- Chrome pruning is load-bearing for search: links inside nav/footer/header/aside/form subtrees are never results (tests pin that an engine's footer can't fake a result hit), and harvested links pointing at known engine domains or the SERP's own host are dropped.
- HTML entities are decoded in the body via the emitter and separately for the raw `<title>` (numeric + named forms).
- Tests cover redirect unwrapping, chrome/tag classification, SERP harvesting without leaks, query fitting, and link extraction.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
