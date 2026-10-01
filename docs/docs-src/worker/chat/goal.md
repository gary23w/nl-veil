# goal

**File:** `src/worker/chat/goal.zig`  
**Module:** `worker/chat`  
**Description:** Goal mode — the auto-loop with a goal it keeps, a record of what it tried, and a measure of whether each step helped.

---

## Purpose Summary

The afk tier proved the idea of a loop that writes its own next step, and showed what it lacked: no stored goal, no record of iterations, no measure of improvement, and no reason to stop except a text match on DONE or the human. This module is those four things. A goal is one object per conversation (`goal.json`); each iteration is pick → do → measure → record, logged in `goal_log.jsonl`; the loop ends on its own when the goal is achieved, when its budget is spent, or on a plateau (three iterations in a row that improved nothing). A `--forever` goal, which is also what the afk toggle now means, has no finish line and no plateau stop.

## Key Exports

- `parseCommand(text, buf)` — the `/goal` grammar: `/goal <text> [--forever] [--budget N] [--check <command…>]` starts one; `/goal` or `/goal status`; `/goal stop`; `/goal resume`; `/goal forever`; `/goal budget N`; `/goal check <command>`. Anything else is `.none`
- `Goal` — text, status (`active` / `achieved` / `plateau` / `budget` / `stopped`), `forever`, `budget` (total iterations, 0 = unlimited), `check`, the iteration counters and the best measured score
- `State` — the conversation's goal for one turn: `load`, `save`, `start`, `setCheck`, `stepsLeft`, `record(step, verdict)` (folds one measured iteration in, appends the log row, returns why the loop must stop now, or null), `finish`, `apply(cmd)` (a non-start command and the reply the user reads)
- `Verdict` + `parseVerdict(reply, evid)` — the judge's one line (`IMPROVED | score: 12/14 | evidence: …`); anything unreadable is SAME with no score
- `decide(goal, verdict)` — the final outcome: when this iteration and an earlier one both carry a score the comparison is arithmetic, otherwise the judge's word stands
- `pickQuestion(buf, goal, log, memory_rule)` — the question that shows the log and asks for the best improvement not yet tried (DONE is offered only to a finite goal); `JUDGE_SYSTEM`, `judgeQuestion`
- `logTail` / `formatLog` — the newest iterations as the picker's list; `statusText`, `summaryText` — what the user reads

## Dependencies

`std` only. The model calls and the turn loop stay in `engine.zig`.

## Usage Context

`engine.runTurn` parses the command at the head of every chat turn (so the desk, the web app and `veil chat` all have it), loads the state, and when the goal drives the turn: anchors `goal_text` on the stored goal, arms the loop whatever tier the client sent, measures each settled step with `goalJudge` (prompting role, tag `goaljudge`) before the picker runs, asks the picker `pickQuestion`, and ends the turn through `goalEnd` on achieved, budget or plateau. A goal drives the loop on the turn that starts it, on `/goal resume`, on a continuation (“continue”, the desk’s auto-loop kick) and in the afk tier; any other message runs as an ordinary turn and leaves the goal stored. Each measured iteration is emitted as a `goal` event and a status line.

## Notable Implementation Details

- An iteration that ran no tool is SAME without a model call: nothing was changed, so there is nothing to grade.
- The judge reads tool results, never the assistant’s claims; a dead or confused judge can never count as progress.
- A resume resets the plateau count (a fresh look), and raising the budget reactivates a goal that ended on it.
- The afk tier with no stored goal adopts the conversation’s first message as a forever goal, so the run-until-stopped promise holds while afk gains the log and the measurement.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
