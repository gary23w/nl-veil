# writer

**File:** `src/worker/writer.zig`  
**Module:** `worker`  
**Description:** The small-model WRITING faculty — a grounding scaffold that makes a weak model produce coherent, grounded artifacts instead of fabricating. Sources are numbered so the model cites by [N] and never types a URL it could invent.

---

## Purpose Summary

A weak model asked to "write about X with sources" will invent links. This module removes that
option: the engine retrieves real sources itself, shows the model only numbered titles, then
resolves every `[N]` back to the verified URL and strips anything the model invented anyway.

## Key Exports

- `MAX_SOURCES` — cap on the numbered source list (12)
- `compose(w, ground, topic, context, round)` — the writing entry: grounded in fetched sources, or
  synthesized from the hive's own knowledge when `ground` is false
- `normalizeFacts(w, candidates, evidence)` / `normalizeMessage(w, raw, evidence)` — the same
  grounding affect applied to a weak model's lexical writes (memory, messages)

Internal machinery (unit-tested against fixed buffers):

- `buildNumberedSources` — parses fetched "- TITLE / URL / snippet" text into `[1] title …` display
  text with a parallel array of real URLs; dedups; the model-visible text carries NO urls
- `resolveCitations` — replaces each valid `[N]` with a real markdown link, drops out-of-range
  numbers, strips model-typed links and bare URLs ("(source unverified)"), removes storage-wrapper
  noise; returns `cited` (valid citation occurrences) and `grounded` (distinct sources used)
- `seedSources` — engine-side retrieval via the shared web-search chain, with per-round seed and
  domain-diversity accounting for the publish gates

## Dependencies

- `worker/run` (`Worker`) — the swarm runtime this faculty serves
- `worker/tools` — `searchWeb`, the shared retrieval chain

## Usage Context

General machinery with NO baked-in use case: subject, persona, tone, and structure come from the
swarm's goal text; a news desk, research desk, and status desk all use the same `compose`.
Publishing is a separate concern (run.zig orchestrates it) — this module never references any
publishing capability.

## Notable Implementation Details

The enforced RAG floor: the model can only reference a source by number, so a fabricated citation
is structurally impossible — an out-of-range `[N]` simply disappears in resolution, a typed URL is
replaced with "(source unverified)", and `grounded`/`cited` counts feed the acceptance gates.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
