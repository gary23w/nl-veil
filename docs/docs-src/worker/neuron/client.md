# client

**File:** `src/worker/neuron/client.zig`  
**Module:** `worker/neuron`  
**Description:** The neuron-db bridge — the client the engine calls for every recall and observe. It shells the compiled `neuron` binary (or a warm in-RAM field) and fails open, so a missing memory engine degrades to a no-op rather than breaking a run.

---

## Purpose Summary

`neuron/client.zig` is the memory bridge between the worker and neuron-db, the associative store that makes the moment loop an oscillation: perception becomes graph, and each prompt is rebuilt from a trust-weighted recall instead of carried as flat text. The client wraps the recall/observe/import operations the engine and the hive share, and it is fail-open by design — when the `neuron` binary is absent every operation no-ops so the run still proceeds.

## Key surfaces

- recall — trust-weighted associative lookup that grounds a prompt
- observe — write a fact/edge into a memory scope (per-conversation, shared knowledge, playbook, …)
- import — bulk-load a `.facts` pack into a scope

## Dependencies

- the external `neuron` binary (fetched + built on first run; reused after)
- `gateway/http` / worker plumbing for path and process handling

## Usage Context

Called on every recall and observe across the hive and the chat brain. Optionally fronted by the hyperspace grounding field (`NL_HYPERSPACE=1`), which settles the most relevant memory into RAM so a typical round does zero database subprocess calls for grounding.

---

*Documentation generated for nl-veil — worker/neuron/client.zig source analysis.*
