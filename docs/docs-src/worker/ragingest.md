# ragingest

**File:** `src/worker/ragingest.zig`  
**Module:** `worker`  
**Description:** Local-file RAG ingest — absorb an arbitrary text file (a book, a doc, notes, a dataset) into the neuron-db knowledge hive as recallable facts, fully OFFLINE: no internet, no rag repo, no LLM.

---

## Purpose Summary

The distillation is deterministic (the same clean-sentence extraction nl-rag's pack builder uses), so a sealed machine can still turn "/path/to/book" into grounded recall. The pipeline: read text → paragraph-join (repairs hard-wrapped prose) → drop code/markup → split into sentences → gate each (length, letter ratio, terminal punctuation) → dedup → tag `[<label>] <sentence>` → write a temp `.facts` pack → import into the target scope with dedup and a flush cap. Every fact then surfaces through the ordinary recall / recall_hive path, so the book is RAG-able like any pack.

## Key Exports

- `Stats { facts, stored, evicted, bytes_in }` — what an ingest did
- `scopeSlug(label, buf)` — a scope-safe slug from a free-text label (lowercase alnum, single dashes, capped at 40; "doc" fallback)
- `docScope(base, label, buf)` — the per-document sub-scope `<base>__doc-<slug>`; the `base__child` convention is what neuron-db's across-recall merges, so a document is reachable from plain hive recall while never flooding (or being flooded by) the shared base scope
- `labelFromPath(path, buf)` — a short filesystem-safe provenance label from a path's basename (extension dropped)
- `distillToFacts(gpa, text, label, cap)` — the deterministic distillation to a `.facts` pack body: one clean declarative sentence per line, provenance-tagged, deduped, capped
- `ingestText(mem, io, gpa, near_dir, text, label, scope, cap)` — full ingest: distill, write a temp pack beside `near_dir`, import via `Mem.importStats` (dedup + flush cap), delete the temp

## Dependencies

- `worker/oscillation.zig` — `Mem.importStats`, the neuron import (the header spells it as `neuron import --dedup --flush <cap>`)
- `std` — file I/O for the temp pack

## Usage Context

Exposed two ways per the header: the `absorb` tool (a mind/chat says "absorb this file") — via `worker/tools.zig` — and `veil rag ingest <path>` via `cli.zig`.

## Notable Implementation Details

- The sentence gate is tuned for books, not doc pages: prose floor 16 (keeps "Call me Ishmael.") and ceiling 400 for long literary sentences — narrower than nl-rag's 40..300 pack-fact window — plus terminal `.!?` and a ≥0.72 mostly-letters ratio that rejects tables, code, and numeric noise.
- Chapter/section headings survive as `[section]` MARKER facts (markdown `#` runs and CHAPTER/BOOK/PART-style openers), bypassing the prose gate: they are the document's skeleton — chapter-aligned paging landmarks and the outline a summary hangs on — and interleave in document order.
- Fenced code blocks are skipped whole; structural paragraphs (lists, tables, quotes, rules, ordered-list openers) never become facts; sentence boundaries require the next sentence to start with a capital/quote/digit so "e.g. foo" and "3.5" don't split.
- The scope is the document's identity and insertion order its document order — a document defaults into its OWN `<base>__doc-<slug>` sub-scope.
- `ingestText` uses `importStats`, not plain import, deliberately: "stored" counts writes and "evicted" counts what the scope's max_facts cap front-drained, so a capped scope's ack can say the document is only partially recallable instead of claiming it whole.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
