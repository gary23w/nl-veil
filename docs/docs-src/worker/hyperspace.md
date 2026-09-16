# hyperspace

**File:** `src/worker/hyperspace.zig`  
**Module:** `worker`  
**Description:** The in-process working-memory OSCILLATOR (Lever 2) — a bounded RAM field of facts, settled by spreading activation around a focus and packed densely into a prompt budget.

---

## Purpose Summary

A per-mind grounding field that sits in RAM over neuron-db. Instead of clipping flat `mem.assoc` pulls into the prompt, a mind warms a `Field` once from the store, grows it in-process as new facts appear (zero subprocess), and each moment "settles" the field around the current focus: a link graph over shared word stems derives a hub/leaf hierarchy, activation seeds from focus overlap and spreads a few hub-biased passes, and the highest-activation, non-duplicate facts are packed into a byte budget. Multi-hop-relevant facts light up even when they share no words with the focus (tested).

## Key Exports

- `DEFAULT_MAX_FACTS` (160) / `MIN_FACTS` (16) / `MAX_FACTS_CAP` (4096) — the field capacity bounds; tunable via `NL_HYPERSPACE_CAP`, which callers clamp into [`MIN_FACTS`, `MAX_FACTS_CAP`], bounding both RAM and the O(N²) settle
- `MAX_FACT_LEN` (400) — the per-fact byte cap; public so the chat overlay can compute the field's own dedupe key (the FNV hash of the capped line)
- `stemHashes(gpa, text)` — a fact's sorted, unique stem hashes (caller owns); `interCount(a, b)` — the intersection size of two sorted stem arrays, the field's similarity kernel. Both public for the chat overlay: its firing check stems the model's text with `stemHashes`, and its tests use `interCount` to show a source tag never enters a line's stems
- `Field` — `init`/`deinit`, plus:
  - `observeLine(raw)` — absorb ONE fact the instant it is created, deduped by content hash, with focus-independent eviction at capacity
  - `ingest(block)` — fold a newline-joined recall block through observeLine
  - `warmFrom(mem, scope, focus)` — the single tolerated subprocess: one wide `mem.assoc` bulk pull merged in (lazily on first use, cheaply re-called every few rounds)
  - `pack(focus_text, budget)` — settle around the focus and return a dense newline-joined block within `budget` (caller owns)
- `recall(gpa, mem, scope, focus, budget)` — drop-in replacement for `mem.assoc(...)` + clip: one wide pull, in-process settle, dense hierarchy-aware pack
- `recallUnified(gpa, mem, scope, hive_scope, focus, budget)` — same, but folds the shared hive knowledge into the SAME field before settling, so cross-scope links route grounding flat per-scope clips would miss

## Dependencies

- `worker/oscillation` — `Mem`, the neuron-db handle `warmFrom`/`recall` pull from
- `std` — everything else; no other machinery

## Usage Context

Two consumers.

`run.zig` (opt-in: `NL_HYPERSPACE` = `1`/`on`/`true`) gives each mind a persistent `hfield` (allocated from the whole-run allocator, capacity from `NL_HYPERSPACE_CAP`), warms it once via `warmFrom`, re-warms it amortized (~1 pull / 6 rounds) so other writers' facts arrive, grows it in-process with `observeLine` whenever the mind stores or receives a fact, and packs ~2600 bytes of settled grounding into each moment prompt.

The chat engine's [recall overlay](#doc=worker/chat/overlay) (`worker/chat/overlay.zig`, on unless `NL_MEM_OVERLAY` is `0`/`false`) builds a fresh `Field` for each chat turn — capacity from the same `NL_HYPERSPACE_CAP`, default 256 there — seeds it through `observeLine`, packs it around a live cue before each chat call, and frees it when the turn ends. It never calls `warmFrom`, `ingest` or `recall`: its one store pull is the engine's own `assocAcross`, and its tags, refractory and firing state live beside the field in `Overlay`.

## Notable Implementation Details

- Similarity is the intersection count of sorted FNV stem hashes: lowercased tokens of length 4–40 (digits split tokens, as whitespace and most punctuation do), stop-words dropped, at most 24 stems per fact. There are no vectors, no embeddings, and no index structure — the field is a bounded O(N²) computation by design.
- `settle()` recomputes the expensive degree/radial hierarchy only when facts were added/evicted (`deg_dirty`); a steady moment just re-seeds activation and runs 4 hub-biased spreading passes.
- Eviction is focus-independent: the least-connected (most peripheral) fact goes, so general skeleton hubs survive; before any settle has run, index 0 is evicted instead of a meaningless argmin — the oldest fact the first time, but `swapRemove` then moves the newest fact into that slot. The dedupe key is removed with the victim (a test pins `seen.count == facts.len`).
- Per-fact hard cap of 400 bytes; fragments under 12 chars are skipped.
- `pack()` ranks by settled activation plus a small skeleton boost (`0.15 * (1 - r)`), greedily fills the budget, and drops near-duplicates (>0.8 stem overlap with an already-picked fact).
- The `Field`'s allocator MUST be a whole-run allocator, never the per-round arena — the field outlives every round (stated in the struct and enforced at the `run.zig` call site).

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
