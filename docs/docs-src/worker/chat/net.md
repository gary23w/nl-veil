# Gary's 4tope — the working span as a graph, the continuation as its unfolding

**File:** `src/worker/chat/net.zig`
**Module:** `worker/chat`
**Description:** Compaction and continuation solved algorithmically: the turn's working span as a dependency DAG, its critical chain protected from pruning, and the continuation state rendered as a source unfolding of that graph with no model call.

---

## The name

A conversation is a higher-dimensional object that a model can only read one-dimensionally, the way a 4-polytope can only be seen through its net: cells joined along shared faces, cut along a spanning tree and laid flat. The whole question is which tree to cut along. The answer, is the shortest-path tree from where the work stands; and the part that must never be cut away is the longest path back from it. Its sibling is the [tool tree](#doc=worker/chat/belt): the same idea applied to the belt instead of the transcript.

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

ESTABLISHED is a depth-first walk of the shortest-path tree with the nearest child first, which is what makes each derivation contiguous. Steps are not carried (their decisions show in what they then called); a note rides only when it is a distillation (a fold note), and never when it is a net the engine itself wrote. An empty span unfolds to nothing, so the caller can fall back.

**What a line carries.** A result's text is its *payload*, not its envelope: `payloadOf` finds the one long string field a JSON-answering tool keeps its output in (Agent Garrett's shell tools answer `{"cursor":..,"output":"...","running":..}` inside an EVIDENCE wrapper, and the first 240 bytes of that are cursor and done_by), and the graph keeps it head and tail to `RESULT_KEEP = 3000`. A result on the **critical chain** renders at that length; every other result is clipped to `EXCERPT_MAX = 240` with a `...` mark. Measured on the first long chat this was checked against (conv c477179e8, 2026-10-14) every ESTABLISHED line had been envelope and none of it output.

**`unfoldWith(budget, ground, Opts)`** is `unfold` with three extras a fold needs: `tail_from` (nodes from that index on are the caller's verbatim tail — never carried, still part of the distances), `next_label` (what introduces the frontier's words; a finished turn's record says ENDED ON), and `earlier` — the lines an earlier fold or pass established, carried under EARLIER inside a third of the budget, whole lines. **`earlierLines(span, budget)`** produces them: every `- r` line of every net note (`NET_MARK`) and continuation row (`CARRY_MARK`) in the span, the failed calls first, each once. That is how a second fold keeps what the first carried and a third pass keeps what the first established; the net itself never selects a net note or an engine row as a node, so without it each fold or pass knew only its own rounds. The tots carry a fold's lines the same way.

## In the engine

- **Pruning protects the chain.** `compactWorking` builds the graph before `pruneToolResults` and passes `protectedIds`: a live result on the critical chain is never stubbed however old, replacing "keep the newest 32 KB" as the thing a prune must keep.
- **The fold is the net.** When pruning alone does not bring the span under budget, `foldSpanByNet` turns the rounds older than the kept tail into ONE assistant note — `NET_NOTE_HEAD` + the unfolding of the whole span with the tail excluded + EARLIER from any fold already in it — and the tail rides after it verbatim. No model call: the summarizing fold (`summarizeWorkingSpan`) is now the fallback for a span the net finds nothing in, and the whole path under `NL_HANDOFF=model`. The note's budget is a quarter of the working budget (`netNoteBudget`, 4-48 KB), so every fold shrinks the span.
- **The carry is the net, sized to the window, and the passes chain.** At the spend ceiling the engine unfolds the turn's span under `carryCap` — a thirty-second of the model's window up to 32 KB and half the recency window, never less than the old `handoffCap` — with `earlierLines` of the span, so a rolled segment's carry holds what every pass before it established and ruled out; the previous carry is a system row in that span, which the net never selects on its own. Zero model calls, verbatim bytes, dead ends included. `NL_HANDOFF=model` restores the model-written state; the model writer also runs when the net is empty.
- **The net outlives the turn.** A finished turn's whole working span is unfolded once more (`netRecordFromSpan`, ENDED ON instead of NEXT) and appended to `{conv}/net.jsonl` with what the turn was asked; a cut the engine settled on goes there too. The next turn's `assembleHistory` projects the ledger (`injectNets` / `selectNets`: the newest record whole, older records' lines newest-first, each line once, under `netBudget` — a thirty-second of the window, 1-16 KB) as one system turn after the FACTS block. The rolling summary reads only messages.jsonl, where a turn's tool results never land; this is the layer that carries *what the tools showed* from one turn to the next.
- **Memory as the chat runs.** Tool findings are banked into neuron-db at every step boundary that produced any (one batched subprocess per such step), not only before a fold deletes them, so later steps' recall can reach them and the carry is a layout of what is already remembered rather than the only copy of it.

## Exports

- `Graph` (`fromSpan`, `deinit`, `criticalChain`, `protectedIds`, `unfold`, `unfoldWith`, `Opts`), `Node`, `Kind`, `Dep`.
- `looksDead`, `distinctiveTokens`, `jsonStr`, `payloadOf`, `earlierLines` — the readers.
- `EXCERPT_MAX`, `NEXT_MAX`, `RESULT_KEEP`, `NET_NOTE_HEAD`, `NET_MARK`, `CARRY_MARK`, `EARLIER_HEAD`.

Tests build a three-round span (a read that mattered, a read that did not, a failed run, a fix, a frontier) and pin: results hang off their issuing step and steps depend strongly on what they reused; the critical chain follows reads rather than the bare thread and excludes the never-used read; a superseded read is off the protect set; the unfolding carries NEXT, ON DISK, the failure and the chain in tree order, each once, under budget, and nothing from nothing. Further tests pin the payload reader on the shell envelope (output, not cursor; a listing is not its longest filename; a payload key beats an unknown one), the chain at length against an off-chain excerpt, a tail kept out of the net with the frontier labelled as asked and EARLIER clipped to whole lines, and `earlierLines` over a note and a carry row (failures first, once each, a user line never counts).

See [engine](#doc=worker/chat/engine) for the two sites, [belt](#doc=worker/chat/belt) for the other tree in this directory (the tool map is the same shape with different leaves), and [context](#doc=worker/chat/context) for the fold the net now runs ahead of.

The same algorithm runs in the tater-tots' runtime (`cloud/tot.js`: `loopGraph`, `criticalChain`, `unfold`, `netFold`, `netOf`), where it folds a step's do loop past its window and is the carry between iterations; see [cf_tot](#doc=config/cf_tot).
