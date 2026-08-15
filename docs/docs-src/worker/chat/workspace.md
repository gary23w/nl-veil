# workspace

**File:** `src/worker/chat/workspace.zig`
**Module:** `worker/chat`
**Description:** The prompt workspace — every non-transcript block that enters the LLM context becomes a typed, provenance-carrying, scored **bid**; a deterministic packer admits bids in a fixed order under per-channel byte budgets, stamps each admitted block with a receipt the model can cite, and writes one JSON decision line per turn.

---

## Purpose Summary

Before this module, nine call sites appended context blocks — durable memory, the tool digest, the trust belt, image OCR, relevance recall, belt corrections, family context, plugin hooks, the file ledger — directly into the prompt buffer. Each had its own clip, but nothing bounded the **sum**, nothing recorded what was dropped, and a recalled fact arrived as naked prose with no source attached. The workspace makes admission explicit: one place decides what may enter the context and at what cost, and `{conv}/workspace.jsonl` records exactly what the model saw and what it didn't, why.

## The three channels

Placement mirrors the engine's prompt-cache layout and must never be reordered:

| channel | renders | carries |
|---|---|---|
| `prefix` | right after the system prompt (turn-stable, provider prefix-cache safe) | durable memory, tool digest, trust belt, image OCR |
| `varying` | after the pinned goal, before the recency window (changes per message) | recall, verifier, corrections, family context, plugin hooks |
| `suffix` | after the recency window | the engine's ground-truth file ledger |

Within a channel the order is fixed by `Kind`, then bid order — **never by score**. Score only decides who is dropped under budget pressure, so byte layout stays stable across turns with the same inputs, and the prefix cache keeps hitting.

## Score is not confidence

Two separate fields, deliberately never blurred:

- **`score`** — packing priority: who survives when a channel is over budget. An engineering knob.
- **`conf`** — a **measured** number when the source has one (the top recall hit's coverage). It renders in the receipt and lands in the log; when no measurement exists the log says `null`, never an invented number.

## Receipts

Every admitted block ends with a one-line provenance stamp:

```
[provenance recall: chat:cli7f3a1c, 6 items, conf 0.82, 1480B]
```

Truthful fields only — source handle, item count when known, measured confidence when the source carries one, bytes, whether the block was clipped. The point is that a fact in context stops being anonymous prose: the model can cite where a claim came from, and a human reading a transcript can too.

## Budgets and drops

Per-channel byte budgets (12 KiB prefix / 8 KiB varying / 2 KiB suffix) over rendered content. The call sites' own per-block clips keep normal turns well under these — the budget exists to bound the pathological stack and to make any drop **visible** in the log instead of silent. Drops are whole-block, lowest score first: a truncated correction is worse than no correction.

## The decision log

One line per turn appended to `{conv}/workspace.jsonl`:

```json
{"ts":1755266000,"basis":"cli7f3a1c","budgets":{"prefix":12288,"varying":8192,"suffix":2048},
 "bids":[{"kind":"recall","src":"chat:cli7f3a1c","score":0.60,"conf":0.82,"n":6,"bytes":1480,
          "admitted":true,"clipped":false}, …]}
```

"Why did it say that" has a queryable answer: here is everything that bid for the model's attention this turn, with scores, sizes, and outcomes.

## Scored recall, contested facts, and the tier-2 verifier

The recall bid rides the neuron CLI's `recallscored` verb when the binary provides it: top-k facts with numbers, rendered as a numbered strongest-first list. Facts the store's consolidation scan flagged arrive labeled inline — `[CONTESTED — a stored fact disagrees: "…"]` — with the disagreeing sibling's text. An older binary (or an empty scope) falls back to the legacy prose path byte-identically.

On top of that sits a **sentinel-gated second opinion**: a pure, always-on check (any contested fact, or a weak top hit) decides when to spend one bounded completion on the *thinking* role (`memverify` in the trio routing audit) auditing the block **before** the answering model reads it. Verdicts **annotate, never delete** — a doubted fact gets a caution note bid rendered directly after the recall block; deleting memory on a model's say-so would be the recall-pollution class inverted. Invented fact numbers in the verdict are dropped at parse. `NL_MEM_VERIFY=0` disables the tier; everything fails open.

## Invariants

- **Channel/Kind order is the cache discipline.** Reordering kinds reorders prompt bytes and breaks prefix caching.
- **Capability rides the binary, never the argv.** The consolidation scan is the new neuron CLI's *default* — the engine never passes a check flag, because an older binary would store an unknown flag as part of the fact text.
- **Write cheap, adjudicate at recall.** Contradictions never block a store; they surface where the context is known.
- **Annotate, never delete.** No machine verdict silently removes a memory.
- **Numbers cross seams as numbers.** Confidence is numeric end-to-end and rendered once, at the receipt.
