# the veil — v1.0.1-beta-6

**The sixth beta.** beta-5 gave a runaway turn a spend ceiling and stopped it burning millions of tokens
unnoticed. It was right about the spend and wrong about the work: the turn just *ended*, and everything it
had gathered — files read, pages fetched, dead ends already eliminated — died with it. The next turn started
over and usually hit the same wall the same way. This beta fixes the other half. When a long turn outgrows
its budget the engine now writes down what the stretch established, throws away the bloated context, and
**keeps going on its own**. For a scheduled task the same record is banked durably, so tomorrow's run
continues yesterday's work instead of restarting it.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.0.1-beta-6-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.0.1-beta-6-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.0.1-beta-6-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.0.1-beta-6-linux-x86_64.zip`** |

Unzip it, then run **`veil.exe`** (Windows) or **`./veil`** (macOS/Linux). That single action starts the
server *and* opens the app.

> **Do NOT download "Source code (zip / tar.gz)"** at the bottom of this page. GitHub attaches those to every
> release automatically — they're the raw repo, and building from them needs the Zig compiler. Likewise
> `install.ps1` inside that source archive is a *developer* installer, not the app.
>
> The `veil-server-*` files are the **headless** control plane for servers — no desktop app. Most people
> don't want these.

**Unsigned build:** these binaries aren't code-signed yet, so Windows shows *"Windows protected your PC"*
(click **More info → Run anyway**) and macOS says the developer can't be verified (**right-click → Open**, or
`xattr -dr com.apple.quarantine <folder>`). Signing certificates are still on the list.

---

## 🆕 New since beta-5

### 🧵 A long turn that runs out of budget continues instead of stopping

Before: a turn that crossed the spend ceiling wrote a one-line notice and settled. You came back to a run
parked mid-task and typed "continue" — and the next turn had none of the working context, so it re-read the
same files, re-fetched the same pages, and walked back into the same wall. On a long chat it read as a
near-total memory wipe.

Now, at the moment of the cut the engine spends one small call distilling the stretch into four labels —
**ESTABLISHED**, **ON DISK**, **RULED OUT**, **NEXT** — under about 220 words. *ON DISK* is filled from the
engine's own record of files it wrote, so it is verified rather than claimed; *RULED OUT* and *NEXT* are the
two things a plain summary has no reason to write down and are exactly what stops the next attempt repeating
the first. The enormous working span that tripped the ceiling is then **dropped**, the turn re-seeds from the
distillation, and it carries on. Each pass opens on the same small context a fresh turn would get.

Dropping the span is the point, not a detail: the ceiling fires because every round re-uploads a context that
*grew*. Raising the ceiling buys one more expensive round; compacting resets the cost.

The status line tells you what happened as it happens — *"compacting context (~410k input tokens gathered
this stretch) — distilling what was established"*, then *"context compacted — carrying forward what is
established and continuing (pass 1/3)"*.

Two things deliberately do **not** continue. A turn cut by the **loop guard** still settles: its problem is
repetition, and handing repetition a fresh context to repeat itself in is the one response guaranteed not to
help. And if the distillation fails or comes back empty, the turn settles too — continuing with nothing to
re-ground from is precisely the restart-from-scratch this exists to prevent, minus the human noticing.
Pressing **Stop** still stops, and is re-checked at every boundary.

**What it costs, honestly.** Each pass gets its own re-anchored ceiling, so a turn that keeps going spends
more than one ceiling's worth. By default a turn may continue **3 times** — four segments, four ceilings.
Past that the allowance has to be *earned*: a segment that wrote a file or made a network call it had not
made before buys one more pass, up to a hard bound of **10**. A segment that only re-read its own context
earns nothing, so a spinning turn still settles at 3 exactly where it did before, while a run that is
genuinely getting somewhere is allowed to finish. A maximally productive turn can therefore spend up to
eleven segments of the per-segment ceiling. Both bounds are tunable, and the segment count is visible in the
status line at every boundary.

- `NL_TURN_TOKEN_CEILING` — input tokens one *segment* may spend (default `400000`; `0` disables the ceiling
  entirely). Carried over from beta-5, but it is now a per-segment reading rather than a per-turn one.
- `NL_TURN_CONTINUE_MAX` — default continues (default `3`). **`NL_TURN_CONTINUE_MAX=0` restores beta-5's
  settle-and-wait behaviour exactly.**
- `NL_TURN_CONTINUE_HARD_MAX` — the ceiling on the earned allowance (default `10`).

### 📌 A scheduled task picks up where the last run was cut

Inside one conversation the record above lives in the transcript, and the next turn reads it there. A
**scheduled task** gets a brand-new conversation every run, so it never sees that transcript at all — a task
that kept hitting the ceiling restarted from zero every night, forever.

The same distillation is now also banked in neuron-db as a **resume anchor**, addressed to the *work* rather
than to a transcript, under a namespace of its own. The next run reads it back verbatim before it starts —
no search, no relevance scoring, no guessing at a query — and is told in as many words to treat what it says
is done as done and begin at the step it names. If the run is about something else, it is told to ignore it.

It supersedes rather than accumulates: fifty cuts leave exactly one anchor. Every clean finish deletes it, so
a healthy conversation has none and its prompts are byte-identical to before. If neuron-db is missing or
read-only the anchor simply isn't written — nothing on a hot path fails because a continuation couldn't be
recorded.

### 🧠 Hosted reasoning models stopped starving their own answers

This one is why the above works at all. With a hosted reasoning model configured, the distillation call came
back **empty** — the model spent its whole token budget on hidden reasoning and had nothing left for the
answer. Empty is indistinguishable from "the model had nothing to say", so the engine banked a bare note with
no state in it and the next turn began from nothing. **Ten turns out of eleven** on a live run.

The client had a budget floor for this, but only for *local* thinking models, gated on a model-name guess
that answered "no" for a model visibly streaming reasoning. Hosted reasoning models are ordinary now and
starve identically.

So the fix is **learned, not named**. The signature is provider-agnostic and unambiguous: the call succeeded,
there were no tool calls, reasoning came back, the answer was empty, and the model stopped because it ran out
of room. The client raises the budget, retries once, and remembers the model — every later call gets the
floor up front, so the extra round-trip is paid once and survives restarts. Nothing to configure.

After the fix: 3 of 3 compactions carried real state (~1.4 KB each) against 1 of 11 before, and a single turn
crossed 1.26M input tokens through three compactions to a correct answer.

### 🖥 The desktop shows a conversation someone else is driving

Select a conversation in veil-desk that is being driven from somewhere else — a second desk, a remote client,
a test harness — and you used to get a frozen snapshot: the prompt, no reply, reading as *"the task never
ran"*, and it never updated. Observed live: a run mirrored at 924 bytes on its first turn and stayed there
while the server's copy passed 400 KB.

The cause was a gate on the conversation's *name* (`scheduled_*`) standing in for a property that any
API-driven conversation has. Selecting a conversation now refreshes it from the server unconditionally, with
a guard so a local copy that is *ahead* of the server — turns run on the desk's own engine — is never
overwritten by a shorter one. If you are one person on one desk, nothing changes.

### 🎣 Graders that refuse to pass work that never happened

The unattended simulation harness (`scripts/sim/`) that found most of beta-5 is invisible in the app and
load-bearing everywhere. This round it caught itself.

A 38-turn run executed with the **server down** — every request refused, not one turn run — came back
**EARNED** from two graders. A pristine planted fixture satisfies "the manifest is true"; an untouched source
file satisfies "the contract still holds". Nothing happening was indistinguishable from doing it right, and
would have quietly retired two scenarios as passing. That is the first defect found in the *lenient*
direction, which is the kind that rots a benchmark: a good run scoring badly gets noticed, a dead run scoring
well does not. Every grader now checks for evidence that work happened before it grades anything — absence of
evidence is `NO_DATA`, never `EARNED` — and the driver probes the server before it starts rather than
grinding through 38 connection-refused turns.

Also added: three 12–14 turn long-tail scenarios (a manifest that must stay true across adds, in-place edits,
a delete and a rename; a refactor graded by a test suite hidden until grading time; a suite whose per-run
token cannot be forged because it does not exist unless the program ran), and a **150-turn marathon** sized
backwards from the failure conditions rather than picked — the recency window doesn't begin rolling until
about turn 12–15 and the summary-gap class of bug needs a quarter-megabyte of uncovered span, so the previous
suites stopped right where the interesting behaviour starts. Its output is a curve, not a verdict: recall
accuracy against conversation size, and the turn where it falls off is the finding.

### 🔧 Under the hood

- The compaction note the model reads was rewritten. The old one addressed a human — *"ask for the next piece
  as a new turn"* — which is nonsense at 3am on an unattended run, and it read as a failure, which makes a
  model start over. It now says only that the working context was compacted.
- The harness records per-turn continuity telemetry from the conversation store (transcript size, covered
  offset, summary length, whether the window has rolled) so a wrong answer can be attributed to a context bug
  rather than to the model forgetting.
- Multi-hour harness runs checkpoint after every turn and resume (`--resume` / `SIM_RESUME=1`), so a server
  restart or a sleeping machine no longer costs hours or replays turns into a conversation that already has
  them.
- A bare `except` in the harness hid a missing import for an entire 100-turn run, reporting a measured `0` for
  a field the store said was 257815. A silent zero is worse than a missing one — it pointed at an engine bug
  that did not exist. It surfaces as an error field now.
- One long-standing misreading corrected: `veil` re-execs itself, so the launched process exits while its
  child keeps serving. Repeated "the server crashed" readings were bad PID tracking; the harness probes the
  port instead.

---

*Full changelog: [`v1.0.1-beta-5...v1.0.1-beta-6`](https://github.com/gary23w/nl-veil/compare/v1.0.1-beta-5...v1.0.1-beta-6)*
