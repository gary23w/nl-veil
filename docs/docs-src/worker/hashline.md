# hashline

**File:** `src/worker/hashline.zig`  
**Module:** `worker`  
**Description:** Hash-anchored line edits — an edit addressing scheme that survives weak models and shared files by giving every line a short copyable tag (`42:abc:rst`) the model quotes verbatim instead of re-emitting code or trusting bare line numbers.

---

## Purpose Summary

Text anchors ask a model to re-emit a code line byte-for-byte (models paraphrase; some local chat templates 500 on braces in tool args), and bare line numbers drift the moment anyone else edits the file. Here each line's tag combines a 1-based line number, 3 letters of an FNV-1a hash of the whitespace-normalized line, and 3 letters of a fingerprint of the fixed 8-line chunk around it — so an anchor proves "the neighborhood I read is still there", exactly what a mind needs when other minds edit the same file between its read and its edit. Batches are atomic, and every rejection or success hands back FRESH anchors so the model retries or continues without re-reading the file.

## Key Exports

- `HASH_LEN`, `CHUNK`, `SEARCH_RADIUS`, `CTX_LINES`, `SNIPPET_CTX` — the scheme's constants (3-letter hashes, 8-line chunks, ±15-line recovery scan, context radii)
- `lineHash(line)` / `encode(h, out)` / `chunkFp(lines, idx)` — the hash primitives (whitespace-stable, token-sensitive)
- `Anchor` + `parseAnchor(raw)` — parse `42:abc:rst`, `42:abc`, `0:` (start-of-file), or `EOF`; tolerates a copied `→content` suffix; null = treat as a legacy text anchor
- `isNumberedAnchor(s)` — batch-level dispatch requires at least one numbered anchor (plain code contains "EOF")
- `renderAnchor` / `renderRead(gpa, content)` — the anchored read rendering (`N:abc:def→line`) that makes anchors copyable
- `splitLines(gpa, content)` — line split matching anchor numbering (drops the synthetic trailing-newline tail)
- `Verdict` + `validate(lines, a)` — valid / stale / out_of_range against the current file
- `OpKind`/`Op` (replace with optional inclusive `end_anchor`, insert_after, insert_before; empty replace text = delete) and `Result`/`Applied`
- `applyBatch(gpa, original, ops)` — validate everything, then splice bottom-up, all-or-nothing

## Dependencies

- `std` only — pure library, no I/O.

## Usage Context

The header pins the split: `tools.zig` owns reading/writing the file around `applyBatch()`; this module never touches disk. Imported by `worker/tools.zig` (the edit tool's anchored dispatch) and `src/tests.zig`.

## Notable Implementation Details

- All-or-nothing batches: every anchor validates against the current file before anything is spliced; one stale anchor, out-of-range anchor, or overlapping range rejects the whole batch with the file untouched.
- Rejections carry fresh anchors for the failed region; successes return a fresh-anchor snippet per edited region (recomputed against the NEW lines) — closing the read→edit→re-read loop that dominates multi-step build latency.
- Shifted-anchor recovery: a stale anchor often just moved; the ±`SEARCH_RADIUS` scan names the new line only when exactly ONE position re-validates both hashes — several matches is ambiguity the model must resolve from the fresh context.
- Splices are applied bottom-up (ties: later op first) on original coordinates after an overlap check; a no-trailing-newline original is preserved.
- Hashing is whitespace-normalized (indent/trailing-ws changes don't invalidate; token changes do), and the chunk fingerprint makes edits NEAR a line surface as staleness too.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
