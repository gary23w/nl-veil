# The store — Gary's 4tope as the conversation's memory

**File:** `src/worker/chat/store.zig`
**Module:** `worker/chat`
**Description:** Every message of a conversation captured as it lands, every tool result's payload indexed in neuron-db, and (behind `NL_CONTEXT=net`) every request unfolded from that store instead of carried forward.

---

## Why it exists

Conversation context is captured and retrieved directly.

## Capture

- `{conv}/graph.jsonl` takes one line per message the moment it exists: the ask that opens a turn, each step with its calls, each tool result as the model saw it, each answer, drive and steer messages. Every line is stamped with its turn (`_t`) and a conversation-wide id (`_n`); the ask also carries `"_k":"ask"`. System messages (the engine's own: overlay, ground-truth splices, notes) are not stored.
- Each kept tool result's payload also goes into neuron-db as a document scope of its own, `<scope>__n<id>`, one fact per line (at most 16 KB, 400 lines of 400 bytes), in one `import` per step (`Mem.importDocs`).
- **The gate** (`GateFn`, the engine's `storeGate`): a result that looks like a credential is stored as a stub and indexed nowhere; a memory tool's output is stored but not indexed, so other scopes' facts are not laundered into this one.
- **Fail-safes.** A message that does not end in `}` or does not parse as JSON is never stored; it is counted (`refused`) and the engine says so in a status line. Conv cf5c78765 showed a buffer can hold one: a fold at a stale offset cut the turn brief mid-string. On load, a `graph.jsonl` line that does not parse (a torn append) is skipped and counted (`torn`).
- Capture is on whenever the store is open: with `NL_CONTEXT=net`, or by default (`NL_CONTEXT_CAPTURE=0` turns it off), so a conversation already has its store when the flag is turned on.

## Positions are message counts

conv_buf is never addressed by byte offset here. A reasoning-echo heal rewrites messages in place (offsets move, the count does not), the recall overlay is appended and removed around each call, and a fold replaces messages, after which the engine calls `resync`. `setPrefix` records how many messages the turn's assembled prefix holds; `cuts` finds the prefix end and the newest `KEEP_ROUNDS` rounds by walking message heads.

## Assembly (`NL_CONTEXT=net`)

`assemble(items, budget)` builds one request: the turn's assembled prefix, then ONE system message (`NET_HEAD`) holding the net unfolded from where the work stands over the whole store (past turns plus this one, read as one DAG by `net.Graph.fromSpanWith(.store)`, with long-range links on rare words), then the newest `KEEP_ROUNDS` rounds verbatim. Net lines carry `n<id>`; the `recall_node` tool returns a node whole by that id (`nodeLine`). The engine budgets the net at a third of the working span budget. With the flag on, the turn runs no fold, no carry, no roll and no rolling summary; the spend ceiling stays as a runaway backstop.

## Measured (2026-10-16, stub model)

One scripted conversation (six facts planted mid-file in tool output, 12 filler turns, 5 probes): the v1.1.22 path recalled 0 of 5, `NL_CONTEXT=net` 5 of 5, at 14% more request bytes on average. Graph build is linear in the stored conversation (63 ms at 250 rounds, 620 ms at 2,000 rounds and 8 MB); the unfold itself takes 2-38 ms. Not yet measured on a real hosted model, against prompt caching, or over one very long turn.

## Exports

- `FILE`, `NET_HEAD`, `KEEP_ROUNDS`, `DOC_MAX`, `DOC_LINE_MAX`, `DOC_LINES_MAX`
- `Gate`, `GateFn`, `Obj`, `ObjIter`, `countObjects`
- `Store`: `init`, `deinit`, `setPrefix`, `resync`, `captureAsk`, `capture`, `takeDocs`, `assemble`, `cuts`, and the counters `refused`, `refused_told`, `torn`, `last_nodes`, `last_net_bytes`
- `nodeLine(gpa, io, conv_dir, id)`: one stored node by id, for `recall_node`
