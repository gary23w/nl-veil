# Gary's 4tope — the working span as a graph, the continuation as its unfolding

**File:** `src/worker/chat/net.zig`
**Module:** `worker/chat`
**Description:** Compaction and continuation solved algorithmically: the turn's working span as a dependency DAG, its critical chain protected from pruning, and the continuation state rendered as a source unfolding of that graph with no model call.

---

## The name

Gary Stimpson framed it and named it (2026-10-10). A conversation is a higher-dimensional object that a model can only read one-dimensionally, the way a 4-polytope can only be seen through its net: cells joined along shared faces, cut along a spanning tree and laid flat. The whole question is which tree to cut along. The answer, from the three pages he pointed at, is the shortest-path tree from where the work stands; and the part that must never be cut away is the longest path back from it. Its sibling is the [tool tree](#doc=worker/chat/belt): the same idea applied to the belt instead of the transcript.

## The problem

Both compaction and continuation were writing problems. When the working span grew past its budget a model paraphrased the older part; when a turn crossed its spend ceiling a model wrote a ~180-word CONTINUATION STATE from the head and tail of the log. Both are lossy, both cost a model call, and the second is what a user watched scroll past four times in one task and read, correctly, as the harness losing the thread. Both are retrieval problems, and retrieval has algorithms.

## Three results, one design

- **Longest path is linear on a DAG.** NP-hard in general, but on a directed acyclic graph it is one pass in topological order: each vertex takes the best of its predecessors plus its edge. That is the critical path method on a schedule. A working span is a DAG by construction (every dependency points at something older) and its messages are already in topological order. The longest weighted path backward from the frontier is the **critical chain**: the results the current step transitively rests on. `criticalChain` computes it; `protectedIds` turns it into the set a prune must never stub.
- **A net is cut along a spanning tree, and shortest paths become straight lines.** The prompt is a net of the conversation. The spanning tree to cut along is the **shortest-path tree** from the source, the frontier. Laid out in that tree's order every node appears once (a tree has no overlap) and every derivation chain is one contiguous run of text.
- **Dijkstra with a budget is the selection rule.** Nodes are taken in distance order from the frontier until the byte budget is spent, so what rides is what the frontier is nearest to, not what is newest.

## The graph

`Graph.fromSpan` reads the comma-joined messages conv_buf holds. Kinds: `user`, `step` (an assistant message with tool calls), `note` (one without), `result`, `engine`. Edges are recorded from what is in the span, never inferred by a model:

- a result depends on the step that issued it (by `tool_call_id`), weight 1;
- a step depends **strongly** (weight 2) on a previous-round result whose distinctive tokens its own words or its next arguments reuse (it demonstrably read it), and weakly (weight 0) on the rest of that round;
- a step depends on the step before it (the model's own thread), weight 1.

Distinctive tokens are five-plus characters carrying a letter, with paths and identifiers keeping their punctuation, common words dropped. A later read or write of the same file, or an identical call, **supersedes** the earlier result: stale, so neither protected nor carried. A result whose opening reads as a failure is a **dead end**: carried under RULED OUT, the negative knowledge a paraphrase forgets.

## The unfolding

`unfold(budget, ground)`: Dijkstra from the frontier over the graph in both directions, costs 1 for a read or an issued result or the thread, 3 for a merely-seen result, plus 4 to enter a superseded node and 1 a dead one. NEXT (the frontier's own last words, at most a third of the budget) and ON DISK (the engine's file ledger, verbatim, at most a quarter) are reserved first; the rest is selected in distance order. Layout keeps the four labels the next segment already reads, so nothing downstream changes, but every line is verbatim bytes:

```
NEXT (the frontier, in its own last words): Re-running the tests after the parseHeader fix.
ON DISK: [ENGINE GROUND TRUTH — ... src/parser.zig ...]
RULED OUT (calls that failed; do not repeat them as they were):
- r2 run_tests {} -> ERROR: 2 tests failed parser.test.header: expected MAGIC_V2 accepted
ESTABLISHED (what the frontier rests on, nearest first, each derivation contiguous):
- r4 run_tests {}: All 12 tests passed.
- r3 edit_file {"path":"src/parser.zig",...}: edited src/parser.zig (1 replacement)
```

ESTABLISHED is a depth-first walk of the shortest-path tree with the nearest child first, which is what makes each derivation contiguous. Steps are not carried (their decisions show in what they then called); a note rides only when it is a distillation (a fold note). An empty span unfolds to nothing, so the caller can fall back.

## In the engine

- **Pruning protects the chain.** `compactWorking` builds the graph before `pruneToolResults` and passes `protectedIds`: a live result on the critical chain is never stubbed however old, replacing "keep the newest 32 KB" as the thing a prune must keep.
- **The carry is the net.** At the spend ceiling the engine unfolds the turn's span under `handoffCap` (minus room for the facts-ledger pointer) and commits that as the CONTINUATION STATE: zero model calls, verbatim bytes, dead ends included. `NL_HANDOFF=model` restores the model-written state; the model writer also runs when the net is empty.
- **Memory as the chat runs.** Tool findings are banked into neuron-db at every step boundary that produced any (one batched subprocess per such step), not only before a fold deletes them, so later steps' recall can reach them and the carry is a layout of what is already remembered rather than the only copy of it.

## Exports

- `Graph` (`fromSpan`, `deinit`, `criticalChain`, `protectedIds`, `unfold`), `Node`, `Kind`, `Dep`.
- `looksDead`, `distinctiveTokens`, `jsonStr` — the readers.
- `EXCERPT_MAX`, `NEXT_MAX`.

Tests build a three-round span (a read that mattered, a read that did not, a failed run, a fix, a frontier) and pin: results hang off their issuing step and steps depend strongly on what they reused; the critical chain follows reads rather than the bare thread and excludes the never-used read; a superseded read is off the protect set; the unfolding carries NEXT, ON DISK, the failure and the chain in tree order, each once, under budget, and nothing from nothing.

See [engine](#doc=worker/chat/engine) for the two sites, [belt](#doc=worker/chat/belt) for the other tree in this directory (the tool map is the same shape with different leaves), and [context](#doc=worker/chat/context) for the fold the net now runs ahead of.
