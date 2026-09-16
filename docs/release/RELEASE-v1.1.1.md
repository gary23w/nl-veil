# the veil — v1.1.1

**A point release about memory and staying power.** Nothing in v1.1.0's shape changed. What changed is how
long a conversation can keep going without losing its own past, how the veil remembers you and what it has
just found, and how many kinds of provider trouble a turn survives before it gives up. Most of the work behind
it began with a real conversation failing in a way its own transcript could show; the rest is the model
catalog catching up and the release mechanics v1.1.0 exposed.

**The one you will notice first.** Tell the veil something about yourself mid-conversation and it lands in the
desktop's Memory tab as it happens — not after a restart, and not as a "step" the turn then insists on
re-doing. **The one built for a long afternoon:** a turn that used to re-read the same file after every
compaction now has what it already found offered back to it before every round. That one is pinned by
tests and not yet measured on a live marathon; the limitations at the bottom say so.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.1.1-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.1.1-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.1.1-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.1.1-linux-x86_64.zip`** |

Unzip it, then run **`veil.exe`** (Windows) or **`./veil`** (macOS/Linux). That single action starts the
server *and* opens the app.

> **Do NOT download "Source code (zip / tar.gz)"** at the bottom of this page. GitHub attaches those to every
> release automatically — they're the raw repo, and building from them needs the Zig compiler.
>
> The `veil-server-*` files are the **headless** server for remote boxes and containers — no desktop app.
> Most people don't want these.

**Unsigned build:** these binaries aren't code-signed, so Windows shows *"Windows protected your PC"* (click
**More info → Run anyway**) and macOS says the developer can't be verified (**right-click → Open**, or
`xattr -dr com.apple.quarantine <folder>`). Signing certificates are still on the list.

**Coming from v1.1.0:** there is nothing to migrate, and the Cloudflare login is untouched — no new scopes, no
second sign-in. New here? The [v1.1.0 notes](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.0.md)
explain what the veil is; this page is only what changed.

---

## What's new since v1.1.0

### Memory rides every thought

**Durable memory is an event the engine observes, never a step it drives.** Say *"I am now 34 years old"* and
the veil writes the right `FORGET:`/`REMEMBER:` pair; the engine applies it, strips the lines from what you
see, and — this is the new part — records that it did so, as an engine row under the reply and a status line
on screen. Before, that silence read as "not done". In the armed loop the step picker named the directive
itself as the next step, fed it back as if you had typed it, escalated to hand-editing the store file —
reading the credentials kept in it into the transcript to "confirm" a line — and closed with a build-verify
over a fabricated deliverable. Four extra messages about a fact the store already held. A memory-shaped step
now counts as done the moment the turn has recorded a change, and a turn that has recorded nothing gets one
engine-framed request for the bare lines, never the picker's prose.

**The Memory tab shows the store the server writes.** The tab had kept reading the pre-split global file,
frozen at the moment the per-user store was created: a fact the veil had just kept never appeared, and a card
deleted there was back in the prompt next turn. It reads the per-user file now, re-reads it the instant the
server announces a change — a new `{"kind":"memory"}` frame on the event stream — and again at the end of every
turn, whether that conversation is in front or in the background. A UTF-8 byte-order mark at the head of the
file no longer hides the oldest memory from the prompt, from dedup or from `FORGET:`, and a directive the model
dresses in a list marker, bold or a code span is still a directive.

**The recall overlay.** Recall used to happen twice a turn: at the start, keyed on the goal, and once per
drive step, keyed on the step text. The reasoning rounds in between — the tool calls, the readings, the
decisions, where a long turn actually lives — saw nothing new. Once the working span was compacted a finding
survived only in the store, which nothing consulted until the next step, and the model re-did the work: one
long research-and-write turn compacted three times and re-read the site's conventions after each one.

Each turn now keeps an in-process working field of its memory — the swarm's activation field, which the chat
engine had never used. It is seeded once from the conversation's own memory, your durable notes exactly as the
prompt shows them (credential values already masked) and the file ledger; grown from every finding the moment
it exists, with no subprocess; settled by spreading activation around what the model is doing *right now* —
the goal, its last narration, its last tool call, the last result — before every round's call to the chat
model (the auxiliary verdict, compaction and planning calls go without it); and rendered as one small advisory
block that is the last message of that one request and is gone the instant the model has answered. It never
enters the transcript, a compaction, a summary or the store.

Advisory means advisory, mechanically. A line shown three renders in a row that the model never picks up is set
aside for the next four, so the overlay rotates instead of insisting. A line the model *does* use — its
distinctive words turn up in the next narration or tool call — has fired: it feeds the next cue and is
strengthened in the store at turn end, so a fact that helped ranks higher in every later recall. It cannot loop,
by construction: a rendering never enters the field, the store or the cue; the cue is built only from strings
the engine holds; every render is bounded and spends no subprocess; inhibition can only remove lines.
`NL_MEM_OVERLAY=0` turns it off, `NL_MEM_OVERLAY_BYTES` sizes the block (900 by default), and the swarm's
`NL_HYPERSPACE_CAP` sizes the field (256 facts per turn unless you set it).

### A chat without end

Every fold of the rolling summary used to *replace* it with a fresh 250-word rewrite, so whatever a rewrite
failed to restate was gone for good — a decision from turn 5, a path given at turn 12, a preference stated at
turn 30. The transcript was never truncated, but nothing the model was shown could reach that far back.

Every fold now also writes the concrete facts its chunk established to `digest.jsonl`, an append-only ledger
beside the transcript that is never rewritten, and every turn projects that ledger for the live question with
no model call: the newest lines first, then the lines closest in wording to what is being asked and to the
pinned goal. The read is bounded to the ledger's newest 256 KB — a few thousand fact lines, hundreds of folds —
so it costs the same at turn 5,000 as at turn 6; a conversation older than that still reaches its oldest
specifics through the rolling summary. The ledger rides the R2 backup beside the transcript. A conversation from
before this release starts its ledger at its next fold; what earlier folds already dropped is not rebuilt.

The projection is sized to the model on both sides. The summary, the facts block and the recency window all
derive from the reading model's window and capacity and from the summarizing model's, so a 32k model keeps the
memory it had, a large model with a 128k window replays 64 KB of verbatim history, and an 8k local summarizer is
asked for a fold it can actually hold instead of one that never lands — its cursor used to stay put forever. A
small-parameter model with a huge window keeps small-model budgets, and a trace line per turn records what the
turn was allowed to hold. The workdir's `.veil-facts.md` used to refuse new lines at 96 KB and go silent for the
rest of a long chat; it evicts its oldest lines now.

### A failed model call is retried, not surrendered

The retry ladder retried only the failures it could name as transient — a 429, a 5xx, a dropped connection —
three times, a minute in all. An access token that expired mid-turn came back from Cloudflare as HTTP 401, read
as a request error, and ended the turn on its first failure, though the next resolve would have answered.

In a chat turn, every error from a hosted endpoint now goes through one ladder: up to ten retries in a row,
5 seconds growing to 60, about five minutes in all. The count is per provider and model, so a misconfigured
auxiliary model cannot spend the coding model's retries, and any reply restores it. The credential is
re-resolved before each try — the one retry that can land on a 401. Each wait is a status line, *provider failed
(HTTP 401: Authentication error): retrying in 5s (1/10)*, with account ids scrubbed from the text, and **Stop**
ends the wait at once instead of after it. A spent budget ends the turn with an error that reads *gave up after
10 retries* and names the failure. Local endpoints and the swarm's workers keep the old ladder for transient
errors only.

### The desk is no longer disowned by Windows

The desk "hung and crashed" with its frame loop alive: the server answered in under a millisecond, the turn
streamed, the watchdog's heartbeat never went stale — and Windows still swapped in a *"veil-desk (Not
Responding)"* ghost that ate every click, then offered to close the program. The cause was a per-frame,
window-filtered message peek for the hidden tray window, sitting right before raylib's unfiltered poll. With
that pattern Windows stops crediting the poll as reading the queue and flags the window after five quiet
seconds. The peek was redundant — the tray window lives on the UI thread, so the frame loop already delivers its
messages — and it is gone on every platform. Hands off for 30 seconds on the real binaries: the old build was
flagged and ghosted from about 12 seconds on, in 35 of 60 samples; the fixed build never was.

The watchdog now also asks Windows for its own verdict on every sample, and writes *OS SAYS NOT RESPONDING,
frame loop alive* — and the recovery — to `data/desk-hang.log`, so this class of hang is on the record even
when the heartbeat is fine.

### The catalog keeps itself current

The model menus were months behind: OpenAI's newest entry was GPT-5, and Anthropic had neither Opus 5 nor
Fable 5.1. Both binaries embed `models.yaml` when they are built, so a stale file is a stale app.

A daily job now takes each hosted provider's newest qualifying models from models.dev — text output, tool
calling, not deprecated, newer than the newest hand-written entry — and adds one only when a free source confirms
it: the provider's own model list where that answers without a key, otherwise its docs page, LiteLLM's open
catalog or a public model page. **No API key is read or sent.** The models land in a marked block at the end of
each provider's list, the only part the job ever rewrites, so the hand-written entries and the model a provider
switch selects never move; the job runs the acceptance checks and opens or refreshes one pull request. This
release ships its first run: **25 models** across Anthropic, OpenAI, Groq, Google, Hugging Face, Z.ai, TokenGo
and OpenRouter.

The desk's model dropdowns take their sizes from one place now. The Swarm deploy menu built its list in a
16-row array with no bound check and 15 rows already full, so one more provider or a 17th model on one provider
would have written past its end, while the Settings and Tasks menus silently stopped at their last row. The
capacities live in `catalog.zig`, and a catalog that outgrows any menu fails the build.

### Release mechanics and docs

- A tag with a hyphen (`v1.0.1-beta-7`) publishes as a prerelease; a bare version publishes as a full release
  and takes the **Latest** badge. v1.1.0 went out flagged as a prerelease because the flag had been hardcoded
  through every alpha and beta; this is the first release cut with the rule derived from the tag.
- `bump-version.ps1` stamps the docs site's two version chips and the README's sample startup banner too — the
  stamps the bump to this version missed.
- The [docs site](https://gary23w.github.io/nl-veil/) covers every module again. Nine that shipped without a
  page have one — the R2 backup, the tunnel, the `cf_` tool belt, the offline probe, both Winsock clients, and
  the desk's non-alertable sleep, watchdog and prebuilt roles — the dataset page is back in the index, and the
  pages for the engine, the retry ladder, the activation field, the tray and the desk's chat client describe
  this release's code. Source comments this release's own commits had left stale were corrected with them, with
  no change to what the code does. Reading every module against its page also turned up the gaps listed under
  *Found while writing these notes* below.
- The installers' own headers advertised one-liners that 404 (the scripts moved into `scripts/`); they point
  at the live path now, and the README's install links use the repository's canonical name.

---

## Known limitations

The [v1.1.0 list](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.0.md#known-limitations)
still holds in full — unsigned binaries, no HTTPS on the LAN, listening on every interface by default, admin is
in effect a shell on the host, and the tool belt wants Python on `PATH`. Additions about this release's own work:

- **The recall overlay and the facts ledger are oracle-green, not yet measured live.** Every behavior claimed
  above is pinned by a test; how much a long conversation actually gains has not yet been read off a marathon
  run against a live server.
- **The overlay does not seed everything it could.** The shared hive knowledge is still reached only through
  the per-step recall's relevance-gated fallback, the facts ledger only through the per-turn projection, and the
  resume anchor not through the overlay at all.
- **The ledger's projection matches on words, not meaning.** An old fact comes back when the question shares
  wording with it; a paraphrase that shares none will not pull it back, though the newest lines are always
  present.
- **A provider that is down for good costs one full ladder** — about five minutes of status lines — before the
  turn gives up. Stop ends the wait at once.

### Found while writing these notes

None of these is new in this release, and none is fixed in it; each is written down so nobody has to rediscover
it.

- **The `cf_` tools run only in turns the server executes itself — the web app and scheduled tasks.** The
  desktop app and `veil chat` hand tool calls to a client-side executor that holds no Cloudflare credentials, and
  have since before the belt shipped, so from there a `cf_` call answers that it is not connected. A non-admin
  account is shown the family, but its sandbox refuses every call.
- **The desk freeze fix is narrower than v1.1.0's notes said.** The worker loops' tick sleeps no longer park on
  the runtime's thread alert, but four other sleeps on desk threads still do: the server client's retry backoff,
  two waits on the chat thread, and the watchdog's own sampling sleep. The silent-worker line never read as
  promised either — its full text overflows its buffer, so it only ever says *chat thread silent* — and only the
  chat thread's silence is reported; the poller writes a heartbeat nothing reads.
- **Two tunnel edge cases.** Changing a named tunnel's hostname within the same zone moves the ingress but
  creates no DNS record or Access app for the new name; and a quick tunnel started after a named one can report
  Access protection it does not have, because the old policy id stays in the state.
- **The R2 backup never re-creates its bucket.** Once confirmed, the bucket is remembered for good, so after a
  login to a different Cloudflare account, or a bucket deleted on Cloudflare's side, changed files fail to upload
  on every pass instead.
- **A byte-order mark is still invisible to two readers.** The engine's prompt, dedup and `FORGET:` paths strip
  it now; the `get_credential` and `recall` tools do not.

---

**Gate at the tag:** 744 tests in the server suite and 218 in the desk suite pass, the test graph cross-compiles
clean for x86_64-linux, and both the server-only and the full GUI builds complete — `scripts/check.ps1 -Full`,
ALL GREEN.

*Full changelog: [`v1.1.0...v1.1.1`](https://github.com/gary23w/nl-veil/compare/v1.1.0...v1.1.1)*
