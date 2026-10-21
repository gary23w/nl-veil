# family

**File:** `src/worker/chat/family.zig`  
**Module:** `worker/chat`  
**Description:** A conversation family read as one view: the primary chat and its sub-chats, each with a status, a title and its newest answer; each other member's 4tope for a member's net; and the family ledger's records. Read-only by construction.

---

## Purpose Summary

A family is a primary conversation and its sub-chats, `<root>__s1` to `<root>__s5` ([paths](#doc=worker/chat/paths)). Every member keeps its own store: its own `graph.jsonl`, its own `_n` ids, its own `chat:<conv>` scope. This module reads a family without merging any of that. It is handed an allocator, io, the user's chat base and a liveness probe, never a Store or a Mem, and it opens files for reading only. A test holds the code above the module's tests to that: it fails on the write calls it lists (appending, writing, creating, deleting, renaming, a file opened for writing and its writers, a copy, a truncate, a link) and on any import of the store, the engine or the memory client.

Everything it feeds is behind a default-OFF flag. With every flag unset the route is not registered, and no request, file or memory scope changes.

## Flags

`Flags.read(env)` reads all four from one environment. Each is on when set, non-empty, not starting with `0` and not `off`: the rule the engine reads `NL_TOOL_MAP` with, so `false` reads as on.

| Flag | What it turns on |
|---|---|
| `NL_FAMILY_VIEW` | `GET /api/v1/chat/convs/:id/family`. The desk reads the same flag from its own environment and then polls the route for the chat on screen: a status dot and tooltip per tab, sub-chat tabs the 32-row conversation list dropped, and one notice per member that finishes. |
| `NL_FAMILY_STATUS` | The family block a turn carries says each member's status and leaves empty dirs out. |
| `NL_FAMILY_NET` | `off`, `on` or `results`. The other members' 4topes ride in this conversation's net. `on` carries their asks, answers and tool results, `results` their tool results only. |
| `NL_FAMILY_MSG` | The family ledger ([famlog](#doc=worker/chat/famlog)), the `message_subchat` and `report_to_primary` tools, and the engine's done record when a sub-chat's turn ends. |

## Members and status

- `familyRoot(conv)`: the primary itself, or a sub-chat's primary. A branch of a branch, an empty id and an id over 64 bytes have none.
- `memberId(buf, root, n)`: slot 0 is the root, 1 to 5 are `<root>__s<n>`. A built id is read back through `paths.branchParts` before it is returned, and one that would pass 64 bytes is no member.
- `load(gpa, io, chat_base, uid, conv, live)`: the family `conv` belongs to. The root's dir must exist; a sub-chat slot whose dir does not exist is not a member.

A member's title is line 1 of its `messages.jsonl` when that line is a user message (80 bytes). Its answer is the newest assistant message in the file's tail (500 bytes), passing over the engine's own plan rows (the plan shown before the work and the note a finished plan closes on). Both come from one head-and-tail read, clipped on a character, and any byte that is not UTF-8 reads as `?`. A line counts only when it is whole, starts with its writer's prefix and parses as JSON. With `NL_FAMILY_MSG` on, a sub-chat's answer is instead the one its newest done record carries (`answersFromLog`): the answer its turn settled on.

A member's **epoch** (`memberEpoch`) is 8 hex digits of the hash of its `messages.jsonl` line 1, which never changes over a conversation's life. Line 1 is read in chunks to its end (up to 64 MB), so a long first message has an epoch like any other. A slot deleted and opened again starts with a new line 1, and so a new epoch.

| Status | When |
|---|---|
| `running` | the engine's turn table holds this member's slot for this account (`engine.isTurnLiveFor`), asked before any file is read |
| `finished` | the newest whole frame of `events.jsonl` is the closing `{"kind":"done"}`, and that turn wrote no error frame |
| `failed` | the same, with an `{"kind":"error"}` frame in that turn: `done` closes every exit path, so done alone cannot tell the two apart |
| `interrupted` | whole frames after the newest done, and no turn running |
| `empty` | neither file holds a byte (a dir `POST /control` made, a branch opened and never used) |
| `unknown` | anything else: messages without events (an R2 restore), an events tail with no whole frame, a file that cannot be read |

`isTurnLiveFor` reads a slot claimed under uid 0 as live for every account. `tryBeginTurn` claims slots that way for the work the server starts itself (scheduled runs, tot jobs), which run as their owner.

## The route

`GET /api/v1/chat/convs/:id/family` (`service.convFamily`) is registered only while `NL_FAMILY_VIEW` is on; unset, the path is no route at all. The handler checks auth first, and the flag again (404). It is 404 too for an unsafe id, a branch of a branch, or a primary with no conversation dir. Asked from any member, it returns the same family:

```
{"ok":true,"root":"<id>","members":[{"conv":"<id>","status":"<word>","title":"..","answer":".."}]}
```

Every value is a flat scalar escaped by `http.jstr`, and each member is named by its conversation id, so a client parses no label grammar. With `NL_FAMILY_MSG` on, the ledger's newest 20 current records follow the members as `"log":[{"seq","kind","from","to","text","re","status"}]` (see below; open records are left out).

## The family block (NL_FAMILY_STATUS)

Off, a branch's block quotes the primary's goal and latest progress, and a primary's block calls every branch dir ACTIVE and says their findings are already in its shared memory. A golden test pins those bytes. On, the branch side adds the primary's status and its siblings with theirs. The primary side lists each branch that holds anything with its status, and replaces the memory sentence with what is true: a branch's tool findings are recallable (each step's findings are observed into its own scope, which across-recall reaches), but its replies are not, because the engine never observes a reply. Neither are the family's messages: `message_subchat` and `report_to_primary` carry a model's words and are never banked as findings.

## The family in a member's net (NL_FAMILY_NET)

`Pool` reads each other member from the bounded tail of its own `graph.jsonl` and builds that member's own `net.Graph` from it alone. Frontier, thread, rounds, call ids and supersession never mix across conversations. A few nodes are kept as candidates and the graph is freed:

- the newest answer and the newest ask (`on` only);
- the critical chain's live results;
- the newest ruled-out calls;
- the newest other live results, kept for the cue to link.

A result crosses only with a tool name and only when the engine's store gate would keep it whole. That drops memory echoes (`recall`, `recall_hive`, `read_doc`, `observe`, `skill`, `recall_node`), the family's own messages (`message_subchat`, `report_to_primary`), credential-shaped heads, and window-edge results whose call fell outside the tail.

`store.assemble` asks the pool through `Store.family` (`render` and `refresh`) whenever the hook is set. The section goes after the conversation's own net, inside the same system message, under `FAMILY_HEAD`; while the conversation has no net of its own yet, it rides alone in that message's place. The section is capped at a sixth of the net budget and never more than 4096 bytes. Members are rendered round-robin, one line each in turn, so a later member is not starved. A member's lines come in its own order: answer and ask, chain, the results that share a distinctive word with the cue (the frontier's words and its calls' names and arguments), then ruled-out calls. A line that does not fit is skipped and counted.

Each line names its node by a qualified id, `s2.n17@1a2b3c4d`: the member's slot (`main` for the primary), the node's `_n`, and the member's epoch. `recall_node` takes that id as `{"id":"s2.n17@1a2b3c4d"}` or `{"id":17,"from":"s2","epoch":"1a2b3c4d"}`. `recallMember` builds the member's dir from the caller's own conversations root and family root, refuses a missing or changed epoch, and returns the LAST whole, validated line stamped with that `_n`. A slot deleted and minted again therefore refuses the old id instead of naming a node of the new conversation. A bare `n17` is the caller's own node, as before. The tool's definition is chosen on the flag alone, so the tools array holds still while sub-chats come and go.

The pool re-reads its members at most every 15 seconds. A grown store is read again. A member whose store shrank, whose epoch changed or whose dir went is dropped for the rest of the turn. A new member is read.

## The ledger, read (NL_FAMILY_MSG)

`readLog` returns the whole, validated records of the ledger's tail, oldest first. A record is **current** (`recCurrent`) when every sub-chat it names still holds the epoch the record was written with: a record of a sub-chat that was deleted, or whose slot holds another conversation since, is history, and no reader shows it. An open record carries no sub-chat epoch (it is written before the new sub-chat has its first line), so it stays in the file and reaches no reader.

In a member's net the ledger rides ahead of the member lines, in the same section, under `LEDGER_HEAD`, with up to half the cap. A conversation sees only current records sent to it: a sub-chat sees the primary's steers and questions, and the primary sees its sub-chats' results, answers and done records. A steer or a question is spent once a turn of the sub-chat has ended after it (its done record follows it), and a question also once the sub-chat answered it; a spent one is not put to it again. The newest records that fit are kept, rendered oldest first, one line each, framed by their sender (`- ledger #5 s1 done [finished]: ...`). The pool reads every slot's epoch again at each refresh, so a sub-chat deleted and opened again drops its records mid-turn. The ledger is a file, never a memory scope.

## Bounds

Every bound is a starting value, not a measurement: events tail 64 KB, graph tail 256 KB, ledger tail 64 KB, refresh 15 s, section cap `min(net budget / 6, 4096)`, line text 240 bytes (600 for a ledger line), title 80 and answer 500 bytes.

## Measured (2026-10-20, stub model)

One scripted family on an isolated server, every flag off against every flag on, one run each. The primary opened a sub-chat, the sub-chat wrote a fact into a file, the primary asked it a question, and the woken sub-chat answered.

- **Requests.** With the flags on they were 3-7% larger (the primary's first turn 3.3%, the sub-chat's first turn 5.0%, the primary's later turns 5.8% and 6.3%): two more tool definitions, and a family section of 741 to 1,460 bytes with nothing skipped under its cap.
- **Reach.** The fact that lived only in the sub-chat's reply reached the primary's next request with the flags on and not with them off.
- **Speed.** Reading one other member took 0 to 1 ms, at millisecond resolution. `GET /family` on a quiet server answered in a median of 1.7 ms in one run and 5.3 ms in another, about 16 ms at the 95th percentile (60 calls each).
- **Writes under polling.** The route was polled 83 times while the turns ran, and afterwards no message line or done frame was missing. That is counted from the files: the file writer keeps no count of skipped writes. An earlier run of the same harness, not counted above because its script misfired, polled 4,236 and 5,013 times with the same result.

A stub cannot judge answers. Answer quality is not measured.

## Known limits

- The engine releases a turn's slot just before it writes `done`, so for that instant a member reads `interrupted`. The next read says `finished` or `failed`.
- A turn's error frame is looked for inside the events tail only.
- Readers take no lock against the engine's writers.
- Ledger lines reach a model through the net. With `NL_CONTEXT=fold` (or capture off) there is no net, so the messaging tools are not offered and no ledger line reaches a model. The route, and so the desk, still carries the records.
- With only `NL_FAMILY_VIEW` on, a member's answer is the newest assistant row of its file; an answer critique appended after it (a model's note, with no marker) shows in its place, and a final row longer than the 16 KB tail shows the answer before it.
- The desk polls the family on screen only, so other families' sub-chats still finish without a notice.

## Verification

Unit and handler tests in `family.zig`, `famlog.zig`, `engine.zig`, `store.zig`, `service.zig`, and the desk's `store.zig`, `poller.zig` and `chat.zig`. Golden tests pin the flag-off bytes of the family block, `recall_node`, `Store.assemble` and the sub-chat gate. Each tested guard was broken on purpose, one at a time, and its test failed. No unit test runs `runTurn`. Its parts are tested on their own (the turn's answer hand-off, the one-mark rule, the tool map's core), and source checks pin where `runTurn` calls them. The wiring was run end to end on the stub model: the pool's setup, and the definitions joining the tools array (49 tools to 51). Not yet measured against a live model.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
