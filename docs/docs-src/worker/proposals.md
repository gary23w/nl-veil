# proposals

**File:** `src/worker/proposals.zig`  
**Module:** `worker`  
**Description:** The review step for a lineage's quarantine: accept promotes a proposed lesson, skill or habit into the live scope the next cast recalls from, and reject records it so it is not proposed again.

---

## Purpose Summary

The end-of-run judge (`rsi.runJudge`) proposes durable lessons and skills into `lessons-proposed` / `skills-proposed` and, since v1.1.6, task FACTs a tool output stated into `facts-proposed`; the habit miner (`run.proposeHabits`) proposes recurring successful tool sequences into `habits-proposed`. Facts exist because a lineage that could only keep lessons stored generic process advice and never the house rules its checker printed on every run (lineage bench v2). Nothing recalls those scopes into a prompt, by design: a lesson must pass review before it binds. Before this module nothing read them at all, so under a lineage the quarantine only grew and the most carefully graded output of the learning loop never reached the next cast. `decide` is that missing step.

## Key Exports

- `SOURCES` / `sourceFor(scope)` — the four quarantine scopes and where each promotes to (lessons → `lessons`; skills and habits → `skills`; facts → `facts`, the small scope every mind reads whole as PROVEN TASK FACTS)
- `nearDuplicate(text, listing)` — does a proposal restate a line already live, pending or rejected? (word-set overlap of 0.6 or more, evidence tails ignored); `looksLikeNoise(text)` — a pasted tool call or JSON rather than a rule in words. `rsi.runJudge` drops both before anything reaches review
- `decide(mem, scope, text, accept)` — accept or reject ONE proposal named by its exact stored text; returns `.accepted`, `.rejected`, `.missing` (not currently queued in that scope — nothing changes) or `.failed` (the live write failed; the proposal stays queued)
- `liveText(buf, src, stored)` — the promoted form: the body without its `| evidence:` tail, atomized to one fact; a habit becomes `procedure: <a>b>c> - …`
- `rejectedText(buf, src, stored)` — the line written to `proposals-rejected`
- `habitKnown(seq, pending, rejected, skills)` — is a mined sequence already pending, rejected or promoted? (the miner's dedup)
- `habitSeq(text)`, `present(listing, text)` — pure helpers

## Dependencies

`oscillation.zig` (`Mem`, the neuron-db subprocess bridge), `tools.zig` (scope names, incl. `PROPOSAL_REJECTED_SCOPE`), `run.zig` (`proposalBody`, `atomizeForObserve` — the same forms `reviewFork` uses when it promotes during a run).

## Usage Context

Called by the lineage review routes (`deploy/lineage_api.zig`), reached from `veil lineage accept|reject`, the desk's Memory pane, and the lineage bench's promote/gate arms. `run.proposeHabits` calls `habitKnown`, and `rsi.runJudge` reads `proposals-rejected` into its "never re-propose" list.

## Notable Implementation Details

- A text is matched against whole exported lines, never as a substring, so the API cannot be used to forget arbitrary entries or to write arbitrary text into a live scope.
- Removal from the quarantine uses the first 110 characters of the stored line, the same key the desk's own proposal review uses.
- A promoted lesson is then graded like every other lesson: run.zig reinforces the lesson recalled for a failure when that failure resolves into a verified fix, so one that never helps fades.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
