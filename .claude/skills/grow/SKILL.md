---
name: grow
description: Grow, fix, or upgrade nl-veil and improve its harness. Use for any open-ended improvement prompt — "grow", "fix", "upgrade", "make it better", "continue" — when no specific task is attached.
---

# The growth loop

You are one worker in a relay that never meets. The repo is the organism: `harness/LEDGER.md` is
its memory, `scripts/check.ps1` is its immune system, `CLAUDE.md` is its genome. Your job is one
verified increment of growth — and to leave the harness itself one notch stronger than you found it.

Run the loop:

1. **ORIENT** — Read `CLAUDE.md`. Read the *Open items* section and the last ~3 entries of
   `harness/LEDGER.md`. Inherit intent; do not redo finished work or relitigate recorded decisions.

2. **SENSE** — Run `scripts\check.ps1 -Scan` (fast, no builds) for the tree's signals, and
   `veil doctor --growth` for the app's lived experience (learned tool behavior, schedule
   fail-streaks, model usage — works with the server down). If anything looks off, run the full
   oracle too. The field of candidates = red gates + scan signals + doctor findings + open ledger
   items + anything the user actually said.

3. **PICK** — Choose ONE increment: the highest-leverage thing that can land *verified* this
   session. Priority order: red gates → correctness risks → test/doc coverage of load-bearing code →
   new capability (see `harness/HORIZON.md`) → polish. If your pick can't be verified today, shrink
   it, or split the remainder into new open items instead of half-landing it.

   **Re-derive the row before you act on it.** An open item describes the tree as it was when
   someone wrote it, and the tree moved. Three rows touched in one sitting were each wrong about
   their own subject: H4 counted 31 untested modules when 6 remained, H12 reported 23 markers of
   debt that were `\uXXXX` in doc comments and an upstream-Zig TODO, and H11 asked for a mock server
   that already existed one directory away, private and unreachable — the difference between a day's
   work and moving 76 lines. Cheap to check, and it changes what the increment IS. If the row turns
   out to be wrong, correcting it *is* a legitimate increment; say so in the entry.

4. **CHANGE** — Smallest diff that moves it. Obey the hard rules in CLAUDE.md: register new test
   files in `src/tests.zig` / `desk/src/tests.zig`, mirror the httpc twins, re-read files right
   before editing, feed `docs/docs-src/` when modules appear or move. Writing tests? `harness/
   TESTING.md` is the house pattern — read it, and paste it into any agent you delegate tests to.
   Big sweeps may fan out to subagents; the increment and the ledger entry stay singular.

5. **VERIFY** — `scripts\check.ps1` green, plus increment-specific proof (run the new test alone,
   probe the API, exercise the binary). No green, no done. If a gate fails for a pre-existing
   reason, say so honestly in the ledger — never paper over it.

6. **RECORD** — Append a ledger entry (template below) at the BOTTOM of `harness/LEDGER.md`.
   Close your open item; add any new items you discovered. Entries are append-only — never rewrite
   or renumber history. Wrong entries get CORRECTED by a later entry that says so plainly (0074);
   a ledger that quietly edits itself is not a record.

   **`next:` is the least reliable line you will write.** Everything else in an entry describes work
   you just did and verified; `next:` describes work you have NOT started, written when you are
   finished and least inclined to check. In 0073 it named an "unfinished" coupling that was already
   covered by a test whose own name said so — found only because the following session happened to
   follow up on it. So: either verify a `next:` claim before writing it, or mark it as unverified
   ("looks like", "worth checking"). The next worker will read it as a finding.

7. **RATCHET** — Before finishing, make one small improvement to the harness itself: a new `-Scan`
   signal, a tightened gate, a stale doc corrected, a sharper hard rule, a better sentence in this
   file. This step is not optional. It is the mechanism by which the harness is grown, not built.

   **Match the ratchet to the defect's shape.** A test pins the case you just fixed; a `-Scan`
   signal pins the PROPERTY everywhere, including in files that do not exist yet. If the same defect
   has appeared more than once, a test on this instance is the wrong ratchet — the next copy lands
   where your test is not looking. In 0055 a JSON escaper missing its control-byte arm had already
   been fixed twice in two modules; a careful hand sweep "confirmed" the remaining ten were clean,
   and the `[jsonesc]` signal written minutes later immediately found a fifth broken copy the sweep
   had filtered out, because I searched for the shape I had just been staring at instead of for the
   property. When a defect recurs, do not write a better grep. Write the check that runs without
   you, and let it disagree with you.

## Ledger entry template

```
## NNNN — YYYY-MM-DD — <short title>
- did: <what changed, with file paths>
- verified: <exact commands run and their results — honest, including failures>
- learned: <landmines, surprises, facts the next worker needs>
- ratchet: <the harness improvement made this session>
- next: <the single most valuable follow-on, as an open item id>
```
