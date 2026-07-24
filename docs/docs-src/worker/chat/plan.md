# plan

**File:** `src/worker/chat/plan.zig`  
**Module:** `worker/chat`  
**Description:** The veil's durable plan-board — the pure data layer for parsing a task decomposition and its acceptance contract, persisting the board to plan.jsonl, and walking it deterministically.

---

## Purpose Summary

When the veil is given a non-trivial task, its first move is to decompose it into subtasks, each tagged with a triage route — `hive` (delegate to a swarm), `research` (learn/RAG first), or `inline` (build it itself) — plus an acceptance contract (Brief: objective / done_when / watch_for) stating what "done" means before any work starts. This module parses what the model returns, persists the task list, and walks it: the drive loop (chat_engine) executes one pending task per step and marks it done, turning the prompt-level "plan then triage" posture into tracked structure that survives across turns — a follow-up "continue" resumes the pending tasks. Pure + std-only so the parsing/status/selection logic is unit-tested directly.

## Key Exports

- `MAX_TASKS` (32 — a runaway decomposition can't mint an unbounded board), `ROUTE_HIVE`/`ROUTE_RESEARCH`/`ROUTE_INLINE`, `STATUS_PENDING`/`STATUS_ACTIVE`/`STATUS_DONE`.
- `Task` — text, route, status, swarm_id, plus per-task `done_when` (the checkable condition ending this subtask) and `tool_hint` (the planner's suggested tool — a hint, never a constraint). `freeTasks` frees a slice.
- `MAX_BRIEF_ITEMS` (8), `Brief` (`isEmpty`/`deinit`) — the turn-level acceptance contract; every field optional by construction.
- `normalizeRoute(r)` — map a model-supplied route to a canonical value.
- `parseDecomposition(gpa, json)` — `{"plan":[{"task","route","done_when","tool_hint"},...]}` → fresh pending task list; never errors (any trouble → empty slice, the caller's signal to run a normal single-step turn).
- `parseBrief` / `formatBrief` — parse the contract from the same reply / render it for injection.
- `formatPlanLine` / `formatPlan` / `parsePlan` — the plan.jsonl round-trip (bad lines skipped).
- `nextPending` / `allDone` / `doneCount` — board walking; `setStatus` / `setSwarmId` — in-place updates (best-effort on OOM).

## Dependencies

- `std` only.

## Usage Context

Consumed by the chat drive loop (chat_engine, per the header); compiled into the suite via `src/tests.zig`.

## Notable Implementation Details

- `normalizeRoute` also accepts synonyms (`delegate`/`swarm` → hive, `learn`/`rag` → research); anything unknown becomes `inline` — the safe default: the veil does it itself rather than spuriously delegating.
- Two-shot parse: `done_when` is the newer field, and std.json type-errors a *known* field of the wrong shape even under `ignore_unknown_fields` — a planner emitting `"done_when":["a","b"]` on one row would otherwise take the whole board down to empty. A failed strict parse retries with the original two-field row shape, so the plan degrades to what it always was rather than vanishing.
- The brief rides in every inference of the turn (injected below the compaction floor), so `MAX_BRIEF_ITEMS` caps how many done_when/watch_for lines an over-eager planner can mint; a planner that returns only `{"plan":[...]}` yields an empty brief and the turn behaves exactly as it did before briefs existed.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
