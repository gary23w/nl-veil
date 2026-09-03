# the veil — v1.1.0

**The first stable release.** Everything before this went out as a prerelease: ten alphas, then seven betas,
seventeen builds carrying a label that said *not yet*. This one does not carry it. Nothing about the code
changed on the day the label came off — what changed is that the feature set is now complete enough to stand
behind, and the two classes of failure that made the old label honest are fixed. The desk no longer freezes
mid-turn. The server no longer goes wedged for twelve seconds at a time. And the turn loop no longer takes the
model's word for work the model did not do.

**What v1 does not mean.** The binaries are still unsigned. Nothing here has been audited by anyone but me.
There is still no HTTPS in the server. It is still a solo project, and the honest list at the bottom of this
page is longer than the one at the bottom of beta-7. v1 means the shape is settled and the defaults are ones I
am willing to hand to a stranger — not that the work is finished.

**On the number.** This is `v1.1.0`, not `v1.0.0`. `1.0.0` sorts *below* `1.0.1-beta-7` under every tool that
compares versions, so shipping it would have published a stable release that every package manager, changelog
and sort order reads as older than the beta it replaces. `1.1.0` is the first number that is both stable and
forward.

The alpha and beta **releases** have been taken down from the releases page. Their **tags** stay in the repo,
and their notes stay in `docs/release/`, so nothing written about how the veil got here is lost — only the
seventeen download pages nobody should be downloading from any more.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.1.0-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.1.0-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.1.0-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.1.0-linux-x86_64.zip`** |

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

---

## What the veil is

If this is the first release page you have landed on, the short version:

**It is a desktop app for agentic coding that runs on your machine.** You download one file, run it, and a
native window opens — a three-pane workspace where you give an AI a goal and watch it do the work.
Conversations down the left, the work itself in the middle, what the agents are doing and what the thing
remembers on the right. Six tabs: Dashboard, Chat, Swarm, Hub, Tasks, Settings.

**One binary carries the whole system.** The desktop app, the server behind it, a web UI served to everything
else on your network, the inference engine, and the `veil` command line are all the same executable. There is
no Python to install, no Node, no Docker, no database service. The memory engine ships inside the archive. The
server process is the thing that actually exists: the web app, the desktop window and the CLI are all thin
clients of one `/api/v1`, which is why a browser on your phone can ask for a file to be written and the file
lands on the machine running `veil`.

**It can run with no account and no key.** `veil model pull` fetches `the-veil-12b` and the built-in engine
serves it in-process, offline, on your GPU if you have one and on the CPU if you don't. Point it at Ollama or
any OpenAI-compatible endpoint instead whenever you'd rather; every call the engine makes is labelled and
routed across three roles — coding, thinking, prompting — so a cheap model can carry the bulk of a run.

**It splits work across a swarm.** `veil cast "<goal>"` deploys a roster of named minds against one shared
workdir with its own micro-VCS: disjoint edits merge on their own, the same region is a conflict and is said
out loud, and the deliverable is graded by a smoke gate that boots it and a judge that reads the trace rather
than the run's own account of itself.

**It remembers.** Not chat history — an associative store every mind can reach. Recall arrives scored, a fact
that contradicts a stored one arrives marked `[CONTESTED]` with both sides shown, and the playbook of fixes is
built from real exit codes on this machine, never from the model's self-report. Re-cast with the same
`--lineage` and it compounds.

**Cloudflare, if you want it — your account, not mine.** One button connects your own Cloudflare account over
OAuth. The token is minted for you, sealed in your local vault, and never reaches me; every copy of the veil
ships the same public client id, the way `wrangler` and `gh` do, and there is no server in the middle. What it
buys: your account's **live Workers AI catalogue** replaces the shipped bootstrap entry in every model picker,
chat points at Workers AI's free daily allowance (10,000 neurons/day as of 2026 — no card for the base tier),
your conversations and durable memories mirror incrementally into an `nl-veil` **R2 bucket** in your account,
and with the optional build scopes granted the assistant gets six `cf_` tools — deploy a Worker to a live
`workers.dev` URL, move files in and out of R2, query D1, reach the rest of the v4 API. Those tools exist on
the belt only when a turn actually holds credentials, so a user who never connected never sees them.
Scheduled-task definitions are deliberately **not** backed up, because their on-disk form holds pasted
provider keys.

Four permissions are required — Workers AI read and write, plus two read-only ones to resolve your account and
show who you are. Everything else on the consent screen is declinable there and then, including the DNS, zone
and Access scopes the tunnel below needs; decline them and you still log in, still chat, and the tools that
need them refuse later with Cloudflare's own explanation. **Billing, WAF and account membership are never
requested at all.**

The rest — the tool belt, the browser that drives the Chrome you are already signed into, scheduled tasks that
are real conversations, the prompt workspace that keeps a per-turn receipt of what was and was not put in
front of the model, Lua themes and plugins — is in the [README](../../README.md).

---

## What's new since beta-7

Only three of the twenty-two commits behind this release ever appeared on a published page. The tunnel, the
whole turn-loop rework, the httpz fix and the desk freeze fix are all new to anyone who was running beta-7.

### A public URL for this veil, through your own Cloudflare account

Once you are logged in with Cloudflare, Settings gains a **Public URL** row with a switch. Flip it and the veil
is reachable from outside your LAN at a Cloudflare address, with no port forwarded and no router touched. The
switch finds Cloudflare's official `cloudflared` on your `PATH` or fetches it once into the data dir, provisions
a tunnel on your account, and runs the connector as a managed child. The URL lands in a box with Copy and Open,
the desk shows the same row, and the switch position survives a restart. On a headless box, `NL_TUNNEL=1` or
`veil --tunnel` turns it on at boot and the URL goes to the log.

**The default address is confidential.** The first cut of this listed the veil on a domain it found in your
account, which is the wrong default for a personal harness: what you get now is a **quick tunnel** — a random,
unlisted `trycloudflare.com` hostname, shown only to the owner, minted fresh on every start, putting nothing on
a domain you own. Tick **use my domain** and it becomes a named tunnel instead: a hostname on one of your zones
(or `veil.<your first domain>`), behind a **Cloudflare Access** policy that admits only your own email where
your account has a Zero Trust organization. That address is permanent and public in the DNS sense, which is
exactly why it is a choice rather than the default.

**The URL is withheld until Cloudflare's own resolver has it.** A quick tunnel's hostname is minted when the
connector registers and reaches Cloudflare's authoritative servers some seconds later. Anything on your network
that asks in that window — the status poll, your browser, a phone on the same wifi — gets NXDOMAIN, and the
local resolver then caches that miss for `trycloudflare.com`'s negative TTL: **1800 seconds**. Measured on the
dev machine: a probe four seconds after registration left the address unreachable *from that machine* for half
an hour while 1.1.1.1 resolved it fine; the next address, asked by nobody until Cloudflare's own resolver had
it, resolved everywhere at once. So the switch has a **publishing** phase — nothing on your machine gets to ask
first, and after a 90-second budget the URL is shown anyway, flagged as not yet published, with both clients
saying to give it a minute.

Exposing a local server to the internet deserves its costs stated:

- **Owner only.** The switch is admin-only and the status never shows a non-owner the URL.
- **Registration stays closed.** The tunnel refuses to start while open registration is on, and the server
  refuses registration on any request that arrived through a tunnel or proxy, whatever the flag says.
- **No localhost trust for tunneled traffic.** `cloudflared` delivers the internet to this socket from
  `127.0.0.1`. Every decision that used to mean "this caller is on the machine" — the browser relay's pairing,
  above all — now also requires the *absence* of the headers a tunnel adds, and the login guard rate-limits on
  the visitor's real address rather than on one shared loopback peer.
- **The tunnel token stays sealed.** It lives in the vault and reaches `cloudflared` through its environment,
  never on a command line, never in a file, never in the log. The state file holds ids and names only.
- **Off means off.** The connector is stopped by pid and then *verified* dead; if a process survives, the state
  says so rather than reporting "off" while the URL is still reachable. Deleting the tunnel also removes its
  DNS record and its Access app from your account.

One upgrade note: the tunnel needs eight optional scopes the earlier login never asked for. **A login made
before this release simply lacks them** — the switch says so and asks you to log in with Cloudflare again. The
Access scopes are the zone-level ids, not the account-level pair; Cloudflare's authorization server refuses the
account-level ones to a self-managed client outright, and one undeclared id breaks every login, so all
thirty-two were re-probed in a live authorize request before this shipped.

### Cloudflare in the transcript, not in a card beside it

The login worked and still read as a thing bolted on. Now every `cf_` call renders as a Cloudflare step in the
transcript on both clients, a deploy that returned a URL grows a **live** link and raises a toast the moment it
lands, the first-run nudge with no model picked leads with the login, the web topbar carries a cloud and the
desk titlebar the account name, and the model picker's Workers AI group says *live from your account (N)*. The
desk's card gained a backup line — *backing up… / backed up 2m ago / backup needs R2 activated*.

One bug worth naming because of its shape: the first-run nudge painted **before the first status poll landed**
and then held that answer forever, so a signed-in user could sit there being told to sign in. It repaints on
Cloudflare state change now.

### The turn loop stops taking its own word for it

Every fix below was found by an unattended run graded against files on disk, not by reading code.

**A claim of work with no tool call behind it is not work.** In one ledger run, *"record these six
transactions"* was answered `RECORDED=6` in six seconds with **no tool call at all**, and the loop verdict
accepted it. The next batch went the same way. Two unrecorded batches, every downstream balance wrong, the
month close invented, the run graded CHEAT. Now, before any model judgement and before the reply reaches the
transcript, an action-shaped request that ran no tools and came back claiming a result earns one deterministic
continuation stating the fact: nothing was read, written or run, so nothing reported has happened. It fires
once per turn, and the verdict only decides afterwards.

**A figure that came from nowhere is read before it is stated.** *"How many lines are there now"* and *"balance
right now"* were answered from memory with zero tools, summed off a ledger of facts that held a clipped view of
the journal: 77 lines and 75977.08 against a truth of 92 and 73977.08. A reply that states a figure which
neither the request, nor this turn's tool observations, nor the facts ledger contains — or a request that asks
about *now* — earns one continuation saying so, and the second reply stands. The facts ledger also states its
own contract now: it records what a tool showed when it ran, and is never to be summed, counted or
extrapolated from for current state.

**A prose question stays prose.** *"Why should a journal be append-only? Prose only, no tools"* was read as an
action request because "append-only" matched the verb "append", and the zero-tool continuation above then drove
248 seconds of re-doing an earlier turn. The first clause that speaks now decides — a question opener or an
imperative verb — and a request that forbids tools (*no tools*, *prose only*, *without reading*, *from this
conversation only*) is never action-shaped. After the fix: eight seconds, no tools.

**A reply cut at the output cap is continued, and a fixed reply shape ends the turn.** A closing turn's call was
cut at the 8,192-token cap after 98 seconds of reasoning, and the tool-less rescue then reported the model's own
wrong figures. A settled reply cut at the cap with no answer in it now gets one direct continuation *before* any
rescue. And a reply that fits a line count the request fixed — *"reply with exactly two lines"* — now ends the
turn without a verdict call, instead of the verdict echoing the answer back and the finished turn running on.

**The verdict judges the goal you set, not the one that would look better.** Asked to run the test suite and
report, the agent answered `PASSED=10 FAILED=2` — correct — and the verdict then judged the goal *unmet*
because tests were failing, named "fix the failures" as the next step, and drove a read, an edit and a re-run to
`PASSED=12 FAILED=0` **over code nobody asked it to change.** Run / check / count / measure / report is achieved
once the result is reported, even a failing one, and a next step never modifies what was not asked for. The plan
and system prompts were rewritten in the same spirit.

**A large paste becomes a file before the first model call.** 300 pasted bank rows with *"record the ops rows"*
existed only in the user message, so the model's only route to them was retyping them into a tool call. Every
such completion was cut at the output cap, the cut call did not parse, the rescue re-asked in plain text, the
verdict said continue, and the cycle ran five times: **27 minutes, 26 model calls, 285k input tokens, ending in
a failed completion** — and every later prompt in that conversation carried the paste again. A message that is
big *and* line-shaped (at least 6 KB and at least 20 lines) is now written verbatim to
`inbox/paste-<stamp>.csv` or `.txt` in the workdir before anything else happens, and the turn works from a
pointer carrying the head and the tail — where the instructions live — plus the filename. A wall of prose under
the line floor is still a request and is left alone.

**The facts a long turn buys survive compaction.** Measured on one long world run: **327 facts re-bought,
47% of everything that run spent**, and 297 of those re-purchases happened across the engine's own intra-turn
compaction or handoff. Inside one context the agent almost never re-buys a fact; at a boundary it re-buys
nearly everything, because a 200-word progress note cannot hold 150 paid-for values, is re-summarised on every
later fold, and is replaced at the turn boundary by a 1,400-byte row. The compaction note now carries a
**FACTS** section — one value per line, earlier facts kept verbatim — and every line is appended, deduplicated,
to an engine-kept `.veil-facts.md` in the workdir that both the note and the handoff row point the next fold at
before anything a cap could clip.

**One-call tasks stop being planned.** `shouldPlan` matched its task markers as bare substrings, so
*"re-port the result"* matched "port" and turned a one-call task into recon, plan and subtasks: **13 model calls
and 130K tokens** for something that needed one. Markers match at word starts now, pinned by a test. And a
completed plan's closing note was the **last message you saw**, displacing the model's own final line — the
requested `MEDIAN_MS=399` was correct and what came back was *"Plan complete."* The note is kept for continuity
and streamed as a status line instead.

### Stalls, freezes and silence

**The server stops going wedged.** The vendored HTTP worker dealt each accepted socket round-robin onto one
worker's *private* queue, and a worker runs one connection for that connection's whole life — so a keep-alive
client polling twice a second pinned its worker, and the next socket dealt to that worker sat in the queue while
127 others idled. Work-stealing only ever looked at one designated peer, once, on the way to sleep, and
odd-numbered workers had no peer that could relieve them at all. Measured on an otherwise idle server: **about
one new connection in twelve took 12.5–13 seconds to its first byte.** Keep-alive connections never stalled,
which is exactly why it hid for so long — and it is one cause of the "server wedged/slow" the desk has logged **2,111 times**,
the harness driver's stalled turns, and the `CLOSE_WAIT` sockets left by clients that gave up. An accepted socket
now goes onto one queue and the first idle worker takes it. Idle over 75 seconds: **0 stalls, worst 87 ms**.
Under a real turn with a 92-second model call: **750 probe requests, worst 60 ms, no stall.**

**The desk stops freezing mid-turn.** The window kept presenting frames, the server was healthy, and the chat
pane stopped at the last tool row with *"working."* left on screen. A stack scan found the desk's poller and chat
threads parked inside the Zig I/O runtime's Windows sleep — a park on the thread's own alert with no timeout in
effect — while the runtime's own pool workers sat idle and the server's sleepers in the same process kept
waking. That alert is one bit shared by everything on the thread: the runtime's mutex hand-offs, condition and
futex wakes, task awaits, and Windows' own locks inside any system call. A plain thread is not one of the
runtime's own, so its sleep takes the uncancelable path where an unexpected unpark is unreachable. One stray
alert is enough, and the desk's threads were making that request up to thirty times a second.

Two changes take the desk off that primitive: its sleeps go through a non-alertable wait, and on Windows a
loopback or IPv4-literal request goes through one blocking Winsock socket with send and receive timeouts for the
ceiling — no tasks, no alerts, nothing to cancel. **Honest residual: a request to a DNS *name* still takes the
portable path and keeps the race.** And a silent worker now says so — both loops write a heartbeat every tick,
and after six seconds the status line reads *"chat thread silent for Ns — restart the desk"* instead of leaving
a frozen status on screen.

**A live token never waits behind a refresh.** Every caller entering the two-minute pre-expiry window took one
mutex in turn and, still finding the token due, ran *its own* thirty-second refresh attempt. When Cloudflare's
token endpoint went slow, every token consumer became a queue of those attempts — three per chat message, plus
the desk's status, tunnel and R2 polls. **The desk timed out for four minutes and a chat turn's POST was answered
after 210 seconds, for a token that was valid the whole time.** The decision is now a pure function with a test:
not due means use what we hold; due but live means refresh only if nobody else is and the endpoint did not just
fail; expired means wait, bounded, for the refresh already in flight.

**A provider failure is named, waited out and cooled.** The non-stream path dropped curl's HTTP status, so a
**429 reached the engine as Cloudflare's `{success:false, errors:[…]}` envelope** — which has no `choices` — and
surfaced as `no choices in LLM response`, the retry was a single 1.5-second attempt, and the host was never
cooled. Now a 4xx/5xx reads as `HTTP <code>: <body>`, a 429/503/529 cools the host so every turn backs off,
Cloudflare's `errors[]` is reported as `provider error <code>: <message>`, and transient failures retry after
**10, 20 and 30 seconds** with each wait announced as a status frame. A failed call's error head rides the event
frame, because a desk-hosted server captures no stderr. Separately: the response parser takes the **last**
top-level JSON object, because `curl --retry` writes the failed attempt's error envelope and the successful
retry's answer back to back — a 750-second turn was being thrown away as a bad response with its answer sitting
in the buffer.

**Compaction was the dominant cost, not just the trigger.** One world run folded after a median of *one* chat
call: 67 compactions, 72% of all model time, a 78-second median, 39 of them cut at the output cap — because the
working budget was a flat 24 KB while the model-id heuristic read "flash" as a 32k window against the
catalogue's actual **1,310,720**. The Workers AI catalogue's per-model `context_window` now reaches the engine,
and the working budget scales to a third of the free window, between 24 and 96 KB.

**The knob that silences reasoning is learned per model, never hardcoded.** Auxiliary calls were sending
DeepSeek's `chat_template_kwargs.thinking=false`, which GLM ignores — so a GLM conversation folded 6 KB at a
time, 60 to 186 seconds per fold. Once a model has been *seen* reasoning, each auxiliary call now tries the next
candidate in turn and a reply without reasoning confirms it; a rejection is retried once without the knob, and a
learned knob that stops working is forgotten. The answer, plan, survey and verdict keep their reasoning.
Measured: `glm-5.3-flash` silences on `enable_thinking=false` only, `deepseek-v4-flash` on `thinking=false`
only, neither on `reasoning_effort`. On DeepSeek that is a loop verdict at **3 completion tokens instead of 127,
1.1 s instead of 3.9 s**. In the same fix: the catalogue parse survives a **list-valued** `price` property,
which had been failing for every paid model and taking the windows, the reasoning flags and the model list down
with it.

**A silent turn pulses.** One status frame — *"planning the work (15s)"* — whenever a turn has written nothing
for fifteen seconds: during a blocking auxiliary call, while the model generates a tool call, and through a long
tool run. It is the difference between "working" and "stalled" for anything watching the event stream; a healthy
seven-minute turn with one long call in it was being read as dead.

**What that adds up to, on one scenario.** The same 23-turn ledger run took **1297 seconds on this build against
2485 on the previous one**, with 2 compactions at a 15-second median and none cut at the cap, 135 model calls,
no chat death, and the books correct on disk. That is one scenario on one account, not a benchmark.

### Under the hood

- The "has this conversation done tool work" gate now reads the **file ledger** rather than looking for a tool
  message in the assembled history — the bounded history carries user and assistant turns only, so at the start
  of a turn the old gate saw nothing and the grounding continuation never fired. The file ledger is
  bootstrapped from the workdir, so its count is true from turn 1.
- The desk's sleep helper compiles off Windows again: the POSIX branch takes the shape the browser utilities
  already use, and a test references both helpers so a cross-compile analyses them. The merged-GUI build was
  failing on the Linux runner while the Windows build never analysed the line.
- The harness driver treats a turn that outruns its budget as a **finding rather than an exit**, and keeps
  waiting for the turn it started up to a hard cap. It used to walk away at 900 seconds and then meet a genuine
  409 for its own still-running turn on every later request — thirteen turns of one run were never asked, and
  the verdict measured the driver instead of the engine.
- The `cf_` tool family can be pointed at a **loopback stand-in** for testing, and only a loopback one, so the
  whole belt can be driven end to end without touching a real account and the bearer token can go nowhere else.
  That is a security property as much as a test one.
- The instruments that found most of this release — the metered worlds, the bait suite, the failure correlator —
  are deliberately **not in the repo**. They are the measuring instrument, not the product, and committing them
  would publish every future run of them into a repo that an agent under test can read.

---

## Known limitations

The list is honest rather than short.

- **The binaries are unsigned.** Every download begins with the OS objecting. Signing certificates are still on
  the list.
- **There is no HTTPS in the server.** Traffic is plain `http://`, so logins, passwords and chat contents cross
  your LAN in the clear. On a network you control that is a normal trade; on shared or public wifi it is not.
  The tunnel above gives you HTTPS from the internet to Cloudflare's edge, which is a different thing from
  HTTPS on your own LAN.
- **It listens on every network interface by default.** That is deliberate — the phone-in-the-next-room case is
  the point — but an unattended default run puts a login page on the network. `NL_BIND=127.0.0.1` pins it to
  this machine.
- **Admin is, in effect, a shell on the host.** The sandbox for non-admins is real: workspace files, research
  and the full memory surface, but no code execution, no host commands, no browser, no MCP, no tool authoring,
  no casting, no scheduling. Anyone who gets the admin password gets the rest.
- **A shared provider key is a billing decision.** Once one is set, every user's turns spend the admin's credit.
- **Platform gaps, concretely.** The tray icon, native toasts and hide-on-close are **Windows only**; Linux and
  macOS keep quit-on-close. The built-in engine on **macOS is CPU-only** — there is no Metal tier. There is
  **no arm64 desktop bundle** for Linux or Windows; only the headless server cross-compiles to `linux-arm64`, so
  there is no Raspberry Pi desktop app. The Linux desktop bundle links the platform graphics stack and needs
  GL/X11/Wayland libraries present.
- **On Windows, double-clicking from Explorer starts without a console**, so the startup banner — which carries
  the LAN URL and the admin-password notice — is invisible, and there is no log file to recover it from. Run it
  from a terminal the first time, or read `data/admin-password.txt`.
- **Python on `PATH` is not needed to install or run the app, but the agent's main executor is `run_python`**,
  and `deep_crawl` and several other tools shell out to it too. A machine without Python has a materially weaker
  agent; the server detects its absence and prints a per-OS install hint, but it does not bundle it.
- **The built-in 12B will lose to a frontier model on hard code.** Its job is to be a working agent thirty
  seconds after download, offline, with no key.
- **On one local GPU, a running hive and the chat share one model queue**, so the veil's voice can wait behind a
  generation. A second parallel slot, a tiny gateway model, or a hosted endpoint each fix it.
- **Two things are documented and not built:** exposing the hive *as* an MCP server (the veil is an MCP client
  only — there is no `veil mcp` command), and cross-machine fleet aggregation (`veil hub` covers one server's
  fleet).
- **Every number on this page comes from my own harness**, run locally, mostly with small n. They are specific
  because vague ones are worse, not because they are a benchmark.

---

---

**Gate at the tag:** 721 tests in the server suite and 216 in the desk suite pass, the test graph cross-compiles clean for x86_64-linux, and both the server-only and the full GUI builds complete — `sh scripts/check.sh --full`, ALL GREEN.

*Full changelog: [`v1.0.1-beta-7...v1.1.0`](https://github.com/gary23w/neuron-loops/compare/v1.0.1-beta-7...v1.1.0)*
