# pixelrag

**File:** `src/worker/pixelrag.zig`  
**Module:** `worker`  
**Description:** Pixel RAG (Feature 1, Phase A) — ingest a web page as RENDERED screenshot tiles and retrieve over them instead of parsing HTML to text: the shared browser session renders and tiles the page, each tile's visible band-text is indexed in neuron-db, and pixel_search returns tile image paths + text excerpts.

---

## Purpose Summary

Adapts the render→ingest→index→serve shape (from StarTrail-org/PixelRAG, per the header) to this stack, with a DELIBERATE Phase-A divergence: no vision embedding model and no FAISS — a local embedding model would break "no new manual install". So Phase A is VISION-AS-TEXT with no vision model: the retrievable text is the page's own rendered DOM text captured per tile band, scored lexically. The tiles are still rendered SCREENSHOTS, so Phase B (feed the tile image to a vision model) is a drop-in on the same tiles; `NL_PIXELRAG_EMBED_URL` is the named seam for a future multimodal-embedding index (not wired in Phase A).

## Key Exports

- `PIXEL_SCOPE` — the neuron-db scope holding the tile corpus; each fact is `<band text>\x1e<doc>\x1f<tile>\x1f<rel img>`
- `ingest(gpa, io, env, run_dir, mem, url, doc_id, use_daemon)` — render `url`, tile it (1600 CSS px tiles, max 12), write PNGs under `.pixelrag/{doc}/`, index each tile's band-text; returns a JSON summary
- `ingestImage(…, png_bytes, base_url, key, model)` — BROWSER-FREE raster ingest: OS OCR first, vision-model transcription fallback only when the OS path yields nothing and a model is configured; same indexOne primitive as a browser tile, so pixel_search finds attachments with zero retrieval-side changes; returns the extracted text
- `capture(gpa, io, env, run_dir, mem, doc_id, use_daemon)` — snapshot the browser's CURRENT page with NO navigation (the logged-in feed, the open modal, the just-submitted form's result) — the verify half of browser-driven web-app testing
- `search(gpa, io, run_dir, query, k)` — top-k tiles by distinct query-stem hits over the per-run `.pixelrag/index.jsonl` manifest; returns `{doc_id, tile, image, score, excerpt}` JSON

## Dependencies

- `worker/browser/manager.zig` (`renderTiles` / `renderTilesCurrent` in-process) and `worker/browser/host.zig` (`forward` to the local-host daemon)
- `worker/ocr.zig` — OS-native OCR for `ingestImage`
- `worker/llm.zig` — `visionExtract`, the pure-transcription fallback (the prompt forbids describing the image)
- `worker/oscillation.zig` — `Mem.observe`, the durable neuron-db store (also the Phase-B semantic substrate)

## Usage Context

Imported by `worker/tools.zig` and `worker/chat/engine.zig` — the pixel_ingest / pixel_capture / pixel_search tool surface. The `use_daemon` split exists for subprocess-per-call clients (`veil exec-tool`): the persistent local-host daemon renders so ONE browser is reused and Edge isn't leaked across the desk's per-call subprocesses; long-lived server/swarm/CLI-direct callers render in-process.

## Notable Implementation Details

- Stored facts are sanitized single-line (control bytes → spaces, runs collapsed) so neuron-db's newline-delimited store/export round-trips them intact; band text is clipped at 2800 chars.
- `ingestImage` derives a stable content-hash doc id (`attach-<8hex>`) when none is given, so re-attaching the same image reuses its doc instead of piling duplicates; the tile PNG is written even when no text was extracted (an image-only tile), and a failed vision call's error message is never indexed as the image's text.
- `capture` gives each snapshot its own doc generation suffix unless the caller names a doc_id — successive captures of one page (a test loop) must not collapse into one document, or stale states would shadow fresh ones. A blank/about:blank page returns an instruction to navigate first, and an older daemon build answering "unknown action" gets a restart hint.
- The OCR path needs the PNG on disk at an ABSOLUTE path before indexing — the WinRT shim resolves relative paths against the server's CWD, not the run dir.

---

*Case file grounded in the module's `//!` header and public API.*
