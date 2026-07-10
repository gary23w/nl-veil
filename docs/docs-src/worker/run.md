# run

**File:** `src/worker/run.zig`  
**Module:** `worker`  
**Description:** Main worker execution loop: reads tasks from the queue, dispatches to the appropriate handler (LLM, tools, RSI), and reports results.

---

## Purpose Summary

Main worker execution loop: reads tasks from the queue, dispatches to the appropriate handler (LLM, tools, RSI), and reports results.

## Key Exports

- `RunLoop` struct — main execution cycle
- `start()` — begin processing
- `process_task()` — dispatch to handler
- `RunConfig` — queue, concurrency, polling interval

## Dependencies

- `worker/agi` — agent execution
- `worker/llm` — inference dispatch
- `worker/tools` — tool execution
- `orchestrate/neuron_client` — task queue

## Usage Context

Entry point for the worker process. Instantiated by supervisor or started as a standalone binary.

## Notable Implementation Details

Uses a work-stealing queue for task distribution across worker threads. Graceful shutdown drains in-flight tasks before exit.

---

*Documentation generated for nl-veil — run.zig source analysis.*
