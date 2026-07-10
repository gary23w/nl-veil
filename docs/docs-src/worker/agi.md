# agi

**File:** `src/worker/agi.zig`  
**Module:** `worker`  
**Description:** The autonomous general-intelligence worker loop: perception, reasoning, planning, and action cycles with self-reflection and goal tracking.

---

## Purpose Summary

The autonomous general-intelligence worker loop: perception, reasoning, planning, and action cycles with self-reflection and goal tracking.

## Key Exports

- `AgiWorker` struct — main agent state
- `perceive()` — gather observations
- `reason()` — internal deliberation
- `act()` — execute chosen action
- `reflect()` — self-evaluation and goal adjustment

## Dependencies

- `worker/llm` — reasoning via LLM
- `worker/tools` — tool execution
- `worker/run` — task loop integration
- `worker/rsi` — self-improvement

## Usage Context

Runs as the core agent loop. Each worker process instantiates one AgiWorker.

## Notable Implementation Details

The perception-reasoning-action loop runs in a single async task. Reflection is triggered every N cycles or on task failure. Maintains an internal goal stack.

---

*Documentation generated for nl-veil — agi.zig source analysis.*
