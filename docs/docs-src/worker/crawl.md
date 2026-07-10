# crawl

**File:** `src/worker/crawl.zig`  
**Module:** `worker`  
**Description:** Web crawler for resource discovery: fetches URLs, extracts links, respects robots.txt, manages crawl frontiers, and returns structured page data.

---

## Purpose Summary

Web crawler for resource discovery: fetches URLs, extracts links, respects robots.txt, manages crawl frontiers, and returns structured page data.

## Key Exports

- `Crawler` struct — web crawler
- `fetch(url)` — download and parse
- `extract_links()` — discover outbound URLs
- `CrawlConfig` — depth, rate-limit, user-agent settings

## Dependencies

- `worker/commons` — config/error types
- Standard library: http, uri, html parser

## Usage Context

Used by the AGI worker for web research tasks, and by the RSI engine for documentation gathering.

## Notable Implementation Details

Respects robots.txt and crawl-delay directives. Uses a politeness policy that delays between requests to the same host. Supports JavaScript rendering via a headless browser bridge.

---

*Documentation generated for nl-veil — crawl.zig source analysis.*
