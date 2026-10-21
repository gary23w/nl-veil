# famlog

**File:** `src/worker/chat/famlog.zig`  
**Module:** `worker/chat`  
**Description:** The family ledger: `convs/<primary>/family.jsonl`, the one typed, append-only record of what the conversations of a family send each other, with one writer in the process. Behind `NL_FAMILY_MSG`, default OFF.

---

## Purpose Summary

With `NL_FAMILY_MSG` on, the conversations of a family ([family](#doc=worker/chat/family)) talk through this file and nothing else. It is never a neuron-db scope. The tools that write it (`message_subchat`, `report_to_primary`) are never banked into memory as findings, and a turn a family message woke never has its opening observed.

```
{"seq":N,"ts":S,"kind":"<kind>","from":"<conv>","from_epoch":"<8 hex>","to":"<conv>","to_epoch":"<8 hex>","text":"...","re":M,"status":"<word>"}
```

| Kind | Written by |
|---|---|
| `open` | `open_subchat`: the primary opened a sub-chat on a goal |
| `steer`, `question` | `message_subchat`: the primary to a sub-chat |
| `result`, `answer` | `report_to_primary`: a sub-chat to the primary; an answer names its question's seq in `re` |
| `done` | the engine, when a sub-chat's turn ends: whether it failed, and the answer it settled on |

`re` rides only on an answer and `status` only on a done. A record's text is kept to 4096 bytes, clipped on a character. The epochs (`family.memberEpoch`) name which conversation held each slot when the record was written; readers drop a record whose sub-chat no longer holds that epoch, so a sub-chat deleted and opened again under the same id never inherits its predecessor's questions, steers or reports. An epoch the writer could not read is left out: an open record is written before the new sub-chat has its first line, so it carries none.

## Key Exports

- `FILE` (the name `family.zig` defines once), `TEXT_MAX`, `Kind`, `Rec`
- `append(gpa, io, primary_dir, rec, ts)`: the record with the next seq, or 0 when nothing was written
- `recLine(...)`: one record as its line

## Notable Implementation Details

- **One writer.** `append` holds one mutex while it reads the last seq from the file's tail and appends the line, so a seq never repeats or goes back. The tail it reads is sized for the longest line a record can make (a control byte is written as six), and a file left without its final newline by a write cut short gets one before the next record. A data dir has one server (the data dir lock).
- **What the engine does with it** (`engine.zig`). The messaging tools are offered only where the conversation has a net, since the ledger reaches a model through it. `message_subchat` (a primary's, not offered to a sandboxed caller) refuses a sub-chat with no first message, records the message, and then delivers it in one of three ways. A running sub-chat gets it as a steer folded in at its next step; that is reported `live` only when the running turn will read it (`turnWillConsume`). An idle one is woken for one turn on it. Otherwise it is `queued`, and reaches the sub-chat in its net at its next turn.
- **Depth 1.** Only a primary sends, and nothing a woken turn does wakes anyone. A woken turn's opening message is the primary model's words, not the user's, and is never observed into memory. The turn reads its woken mark once, at its start, and clears it as it returns, before its slot is released; a conversation still marked is not woken again. Its plan is decided on the message, not on the frame around it.
- **The done record.** `runTurn` keeps the answer each sub-chat turn commits (the newest is the one it settles on) and whether the turn wrote an error frame, and hands both on as it returns. The record, written after the turn's done frame, takes the oldest hand-off of its conversation, so a turn woken in the instant after another released its slot never lends that one its answer. A plan's closing note, a critique note or a salvaged steer is never taken for the answer. A turn that committed none gives `""`, never an earlier turn's. So the primary gets every sub-chat's answer whether or not a model sent it.
- **No family scope.** While the flag is on, `absorb` into a `family:` scope is refused.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
