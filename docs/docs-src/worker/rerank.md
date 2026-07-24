# rerank

**File:** `src/worker/rerank.zig`  
**Module:** `worker`  
**Description:** SECOND-STAGE relevance reranking over first-stage retrieval, through the run's SELECTED (BYOK / gateway) chat endpoint — no local model, weights, or sidecar, so it works on ANY machine a BYOK download lands on.

---

## Purpose Summary

A cross-encoder reranker is more precise per call but needs downloaded weights + compute + a sidecar, so it can't be the DEFAULT under BYOK; zero-shot LLM reranking through the configured endpoint is the any-machine default (a local reranker stays an opt-in). The design is single-call listwise-select, cost-disciplined to exactly one gateway inference per recall: the model returns ONLY the ids that genuinely answer the query, best first — or NONE. That empty return is RAG's missing abstain floor: the caller can SAY "nothing relevant" instead of injecting the retriever's argmax noise.

## Key Exports

- `MAX_CANDIDATES` (20) — the largest candidate window sent in one pass; first-stage retrieval already narrowed the field
- `Outcome` — `reranked` (order holds kept indices, best-first) | `abstain` (the judge said NONE are relevant) | `passthrough` (could not/should not rerank — use retrieval order)
- `Result { outcome, order }` + `deinit` — order is 0-based indices into the caller's candidates; gpa-owned only when reranked
- `rerank(gpa, io, run_dir, base, key, model, query, candidates, keep)` — rerank against the query via the gateway; an empty model or ≤1 candidate is a clean passthrough so callers can invoke this unconditionally

## Dependencies

- `worker/llm.zig` — `chatTemp`, one temperature-0 call against the run's gateway creds.

## Usage Context

Runs on grounded recall — imported by `worker/tools.zig`. The header ties it to the run's existing gateway plumbing: it rides the same `gw_base`/`gw_key`/`gateway_model` that `screenPass` and `gapToQuery` use.

## Notable Implementation Details

- Position-bias aware: candidates are id-labelled [1..N] and the model answers with IDS, never positions; temperature is pinned to 0 for determinism; one pass, no sliding window. (A second shuffled pass + intersect is left to callers because it doubles cost.)
- The 1024-token completion budget is deliberately generous: a reasoning gateway model spends its budget on hidden reasoning first, and too small a cap returns an EMPTY answer.
- Graceful by construction: any transport/parse ambiguity returns `.passthrough` — the reranker can only improve or no-op, NEVER regress below first-stage retrieval. Abstain (which drops ALL context) fires only on an explicit NONE, never on a mere parse failure.
- `parseRanked` is the pure, unit-tested reliability core: scans integer runs in order, keeps [1..n], dedups, maps to 0-based, caps at `keep`; any valid id wins even amid noise; no ids plus an explicit NONE / "no … relevant" marker = abstain; neither = ambiguous. Candidates are clipped (240 bytes) and flattened to one line each so the `[n]` framing stays unambiguous.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
