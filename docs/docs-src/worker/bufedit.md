# bufedit

**File:** `src/worker/bufedit.zig`  
**Module:** `worker`  
**Description:** The buffer-based, line-addressable file EDIT core — anchor-matched ops applied all-or-nothing to a byte buffer.

---

## Purpose Summary

Everything that surgically edits a file in the worker goes through this module: a batch of `EditOp`s (replace / insert / delete, each addressed by a verbatim text anchor) is resolved against the ORIGINAL buffer and spliced in one all-or-nothing pass. It is pure — no I/O — so `vcs.zig` can use the same `apply` as its merge core, and it also parses the narrated Aider-style `<<<<<<< SEARCH / ======= / >>>>>>> REPLACE` blocks a model emits in prose.

## Key Exports

- `OpKind` — `replace`, `insert_before`, `insert_after`, `insert_at`, `delete`
- `EditOp` — one op: kind + text `anchor` (or `at` line for insert_at) + replacement `text`
- `apply(gpa, original, ops)` → `Applied` — pure, corruption-safe splice; owned rewritten bytes or an owned reject reason
- `Applied` — `ok`, `bytes`, `reject`, `loci`, `reindented` (count of auto-reindented loose matches, surfaced not silent)
- `MatchLocus` — per-op byte offset of the op's landing line in the RESULT — the op's line identity for a later rebase/merge guard
- `parseNarrated` / `parseNarratedSlot` / `Narrated` / `freeNarrated` — SEARCH/REPLACE block parser; the slot variant recovers a pathless edit against the file the engine assigned the mind
- `hasSearchReplace(reply)` — reply is edit narration, not a file body (salvage refuses to commit raw markers)
- `editMarkerCorruption(body)` — line-anchored `<<<<<<<` / `>>>>>>>` fences inside file content are always corruption; a bare `=======` line deliberately does NOT trigger (markdown H1 underline)
- `anchorBrackets` / `Brackets` / `freeBrackets` — the one line above and below an anchor's unique match: its line identity, re-checked against HEAD before an auto-merge

## Dependencies

- `std` only — the module is self-contained and pure.

## Usage Context

`vcs.zig` builds `mergeDecision` directly on `bufedit.apply` and `EditOp`. The `edit_file` tool in `tools.zig` translates model ops into `EditOp`s and applies them (checking `editMarkerCorruption` on the way in and out). `run.zig`'s salvage path uses `parseNarratedSlot` to recover narrated edits from a model monologue and `hasSearchReplace`/`editMarkerCorruption` to refuse committing edit markers as file bodies.

## Notable Implementation Details

- All-or-nothing: max 64 ops; every span resolves against the ORIGINAL, overlaps reject before any mutation, and the splice runs highest-offset-first so earlier edits never invalidate a later span. One bad op fails the whole batch.
- Anchor matching is exact (trailing-trim) first, then a leading+trailing-trim "loose" rescue — taken only when itself unique, so a reindented anchor is recovered without ever making a wrong match; ambiguous anchors reject.
- On a loose match the replacement is re-keyed to the file's indentation, preserving its RELATIVE indent, so a de-indented SEARCH block cannot silently break an indentation-significant file (Python tests pin this).
- A stale anchor is treated as a teammate's concurrent rewrite, not a typo: the reject carries the current file's closest region verbatim ("The file NOW reads …", ~400 chars, no line numbers) so the mind can re-anchor in the same turn; when the region is gone the hint says to read_file instead — never a made-up region.
- CRLF input is normalized to LF for matching and the dominant EOL is restored on output; trailing-newline presence is preserved.
- Refuses an edit that would empty the file or that changes nothing.
- Plain line arrays and range splices — there is no rope structure and no diff algorithm in this module.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
