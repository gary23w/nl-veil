# vcs

**File:** `src/worker/vcs.zig`  
**Module:** `worker`  
**Description:** Swarm micro version-control — serialized, corruption-safe commits so multiple minds can edit ONE shared file. Not git, and no remotes: this is the in-run merge law for concurrent editors.

---

## Purpose Summary

When several minds hold edits against the same file, someone's base is stale by the time they
commit. This module decides what happens then — fast-forward, clean auto-merge, or an honest
conflict — instead of letting the last writer clobber the rest.

## Key Exports

- `Decision` union — the merge verdict a caller acts on
- `mergeDecision(gpa, cur, base, ops)` — given the file as it IS (`cur`), the base the editor saw,
  and its anchored `bufedit.EditOp`s: fast-forward when nobody else moved HEAD; auto-merge a
  disjoint edit onto an advanced HEAD; conflict when a teammate changed the same region (the
  anchor is gone)
- `Result` union — commit outcome
- `Validator` — pre-commit validation hook; a rejected edit leaves HEAD untouched
- `commitEdit(...)` — the serialized commit path: decide, validate, write

## Dependencies

- `worker/bufedit` — the line-addressable, anchor-based edit ops the merge reasons about

## Usage Context

The write path for swarm minds editing shared deliverable files: tools-layer edits flow through
`commitEdit` so two minds merging disjoint changes both land, and a third with a stale base gets a
conflict instead of silent loss.

## Notable Implementation Details

Anchors, not line numbers, carry an edit onto a moved HEAD — if the anchor region survives, the
edit travels; if a teammate rewrote it, that is a conflict by definition. The pre-commit validator
runs inside the commit path (it used to be bypassable around the VCS; the tests pin that gate
shut), and a failed validation leaves HEAD exactly as it was.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
