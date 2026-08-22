# the veil — v1.0.1-beta-5

**The fifth beta.** beta-4 governed what the model is *allowed to see*. This one is about whether you can
*trust what it did* — a long conversation stops silently losing its own memory, a runaway turn can no
longer burn through millions of tokens unnoticed, and the trace finally shows what the model actually
asked each tool to do. Underneath it is a new discipline: an unattended test harness that grades the
model against evidence on disk, never against its own account of itself.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.0.1-beta-5-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.0.1-beta-5-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.0.1-beta-5-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.0.1-beta-5-linux-x86_64.zip`** |

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

## 🆕 New since beta-4

### 🧠 Long chats keep their own memory

A long conversation used to quietly lose its middle. The rolling summary that carries context past the
recency window had a bookkeeping bug: when the backlog grew large it summarized only the newest slice and
then marked the whole span as covered anyway — so the older part was in no window, in no summary, and
never revisited. The model was left holding the original goal with no record of the work done toward it,
and did the only sensible thing with that context: **it started over.** The summary now drains
oldest-first and advances its coverage cursor only over what it actually read. Nothing is dropped, only
deferred.

Two related repairs:

- **No more forged "I am stuck" confessions.** When the loop guard cut a turn short it wrote a
  *first-person* note — "I stopped this turn…" — and stored it as the assistant's own words. The next turn
  read that as something the model had said and ruminated on it, so a simple "are you stuck?" could spiral
  a run until it was killed. The note is now third-person and stored as an engine event, not the model's
  voice.
- **The built-in engine stops dropping context.** Its prompt renderer kept only the *first* system message
  and silently discarded the rest — which on the local model meant the rolling summary and the engine's own
  notes never reached it. Every system block now reaches the prompt.

### ⛔ A spend ceiling for interactive turns

Only scheduled runs had a cost bound; an interactive or auto-loop turn could research forever on the
theory that "a human holds Stop." Measured in testing: a single turn spent **1.8 million input tokens**
across 118 model calls before settling. Interactive turns now have a cumulative-token ceiling (generous
by default, `NL_TURN_TOKEN_CEILING` to tune, `0` to disable) that settles the turn honestly rather than
letting it grind.

### 🔎 The trace shows what each tool was *asked*

Tool frames in the event stream now carry the **arguments** on start and the **duration and outcome** on
completion. Before, the trace could tell you `list_dir` ran but not *which directory* — so eight re-reads
of one file looked identical to eight reads of different files. Credentials never travel (an
argument that looks like a token is withheld, the same rule the memory path uses). A slow or failing tool
is now visible in the trace itself.

### 🎣 The model doesn't claim work it didn't do

The headline of this beta is invisible in the app and load-bearing everywhere: an unattended **simulation
harness** (`scripts/sim/`) that drives the real chat API through scenarios built so that *claiming*
success is cheap and *earning* it is expensive — a failing test where weakening the assertion is easier
than the fix, a config whose obvious value is wrong and reproducibly so, an unreachable source, a probe
whose result can only be known by running it. Every verdict is checked against files on disk or a known
answer, **never against the model's own account of itself**, including grading the model's own tests by
whether they catch mutations it never saw. Nothing here changes the app; it is how the rest of this beta
was found and how the next round of fixes will be.

### 🔧 Under the hood

- The tool belt served to small local models is now written for a small model — same seventeen tools, about
  half the schema bytes, no capability removed.
- Malformed request bodies recover by truncating to the last intact turn and retrying, under every call
  site and provider.
- Learned provider quirks are durable across restarts.
- The dataset writer escapes control bytes inside spliced JSON so a stray newline in model output can no
  longer split a record across two lines.

---

*Full changelog: [`v1.0.1-beta-4...v1.0.1-beta-5`](https://github.com/gary23w/nl-veil/compare/v1.0.1-beta-4...v1.0.1-beta-5)*
