# paths

**File:** `src/worker/chat/paths.zig`  
**Module:** `worker/chat`  
**Description:** One mapping from a conversation id to its build tree, shared by every resolver — engine drive loop, the desk-delegated tool endpoint, cast deploy, and the supervisor's run-dir matching.

---

## Purpose Summary

Ordinary conversations build under `u{uid}/_chat/builds/{conv}`. A scheduled run's conversation (`scheduled_{taskid}_{stamp}`) builds under the task's own permanent directory instead — `u{uid}/_sched/{taskid}/runs/{stamp}/` with files in `{root}/work` — so a task accumulates its run artifacts in one browsable place and nothing deletes them when the conversation is pruned. Sub-chats (`<parent>__sN`) share their parent's build root and reroot their memory scope to the family base. The mapping is a *pure* function of the conv id: every resolver, server or desk, derives the same tree with no side-channel file.

## Key Exports

- `MAX_BRANCHES` (5), `BranchParts`, `branchParts(conv)` — parse a sub-chat id `<parent>__s<N>`; null for ordinary convs, including out-of-range hand-named ids.
- `branchRoot(conv)` — the build-family root: a branch resolves to its parent, everything else to itself.
- `scopeFamilyBase(scope)` — the recall family base: `chat:<parent>__s<N>` → `chat:<parent>`; gated on the `chat:` prefix so swarm/task scopes that merely contain `__s` can never be silently rerooted.
- `SchedParts`, `schedParts(conv)` — parse `scheduled_{taskid}_{stamp}`; the stamp must be a trailing all-digit run timestamp, so a hand-named `scheduled_notes` keeps its ordinary build dir rather than surprise-redirecting into `_sched/`.
- `buildRootRel(buf, uid, conv)` — the data-relative build root for either shape; empty on overflow.
- `buildRootFromChatBase(buf, chat_base, conv)` — the same mapping composed from an absolute `.../u{d}/_chat` base (what the engine's call sites hold); swaps the `/_chat` tail for the task tree on scheduled runs only.
- `schedRunTail(buf, conv)` — the `_sched/{tid}/runs/{stamp}` tail a redirected run dir always ends with; what the supervisor's id↔run-dir matcher needs, since a redirected cast run_dir's basename is the bare stamp, not the conv id.

## Dependencies

- `std` only — pure string/slice work.

## Usage Context

Imported (as `cpaths`) by `worker/deploy/service.zig`, `worker/sched.zig`, `worker/control/supervisor.zig`, and `worker/tools.zig`. Compiled into the suite via `src/tests.zig`.

## Notable Implementation Details

- The id convention *is* the metadata — no side-channel file. A sub-chat's hippocampus scope `chat:<parent>__s<N>` is automatically a `__` child of the family base `chat:<parent>`, so across-recall makes the whole family (primary + branches) one recallable mind while each conv's writes stay attributable.
- Nesting is a single level: the header states a branch of a branch is rejected at the turn gate.
- The header notes `convIdFor` clips a very long task id (> 45 bytes) to fit the 64-byte conv ceiling, and the mapping then uses the clipped id consistently everywhere — so runs still share one stable dir.
- The task's `_sched/{taskid}/` home sits beside its `{taskid}.json` definition; the sched tick/list loops skip directories, so the run tree is inert there.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
