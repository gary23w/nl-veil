![the-veil](web/public/veil.png)

# the veil

<sub>NEURON-LOOPS · ENGINEERING ARCHIVE · FILE NL-VEIL · **THE CASE STAYS OPEN** — read the whole thing twice, then browse the annotated source as a case file at [the docs site](https://gary23w.github.io/nl-veil/).</sub>

<p>
  <a href="https://github.com/gary23w/nl-veil/actions/workflows/release.yml"><img alt="build" src="https://github.com/gary23w/nl-veil/actions/workflows/release.yml/badge.svg"></a>
  <a href="https://github.com/gary23w/nl-veil/releases/latest"><img alt="release" src="https://img.shields.io/badge/release-v1.0.0--alpha.1-A8241B"></a>
  <img alt="zig" src="https://img.shields.io/badge/zig-0.16-F7A41D?logo=zig&logoColor=white">
  <img alt="model" src="https://img.shields.io/badge/model-gary--neuron--emergent-6E4A27">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-31405C"></a>
  <a href="https://github.com/gary23w/nl-veil/stargazers"><img alt="stars" src="https://img.shields.io/github/stars/gary23w/nl-veil?style=social"></a>
</p>

**A hive mind you talk to.** A swarm of autonomous AI minds works a goal together — researching,
building, remembering, **learning from its own mistakes** — while one unified consciousness, **the
Veil**, integrates the whole hive into a single first-person "I" that speaks for it and steers it.

It runs on **any model** — a free local one through Ollama, or a hosted/BYOK endpoint — and needs no
cloud account and no database service. **One Zig binary is the whole thing**: the server, the native
desktop app, the web UI, the memory engine, and the built-in `veil` command line. Download it, run it,
and you're in. No Python, no Node, no Docker.

> ⭐ **If the veil is useful to you, [star it on GitHub](https://github.com/gary23w/nl-veil).** It's a
> solo project — a star genuinely helps it reach the next person who'd get something out of it.

**New in v1** — the **chat brain moved into the server** (clients are now thin; see
[the chat brain](#the-chat-brain-runs-in-the-server)), a built-in **`veil` CLI** that retires the old
Python launcher, **[scheduled tasks](#scheduled-tasks)** that run through chat, a native desktop
dashboard ([veil-desk](#the-desktop--veil-desk)), a swarm that **keeps a playbook** ([it learns](#it-learns)),
and **prebuilt one-click binaries** for Windows, Linux, and macOS. Browse the annotated source as a
case file at **[the docs site](https://gary23w.github.io/nl-veil/)** (`docs/`).

## Install

**Download it and run it — no toolchain, nothing to build.** Grab your platform's bundle from the
**[latest release](https://github.com/gary23w/nl-veil/releases/latest)**, unzip, and run `veil`:

| You're on | Download | Then run |
|---|---|---|
| **Windows** | `veil-…-windows-x86_64.zip` | `veil.exe` |
| **macOS** (Apple Silicon) | `veil-…-macos-arm64.zip` | `./veil` |
| **macOS** (Intel) | `veil-…-macos-x86_64.zip` | `./veil` |
| **Linux** | `veil-…-linux-x86_64.zip` | `./veil` |

That single action starts the local server **and** opens the desktop app.

> **Take the `veil-…` bundle for your OS — not "Source code (zip)".** GitHub attaches a source archive
> to every release automatically: it's the raw repo, building it needs the Zig compiler, and the
> `install.ps1` inside is a *developer* script. The `veil-server-…` assets are the **headless** server
> for remote boxes — no desktop app.

> **Alpha builds are unsigned.** Windows shows *"Windows protected your PC"* → **More info → Run
> anyway**. macOS says the developer can't be verified → **right-click → Open** (or
> `xattr -dr com.apple.quarantine <folder>`). Signing certificates are planned for v1.0.0 proper.

<details><summary><b>Build from source instead</b> — contributors (needs Zig 0.16+)</summary>

These installers **clone the repo and build it**, so they need [Zig 0.16+](https://ziglang.org) on
`PATH`. This is the contributor path, *not* the quick start.

**macOS / Linux**
```sh
curl -fsSL https://raw.githubusercontent.com/gary23w/nl-veil/main/install.sh | sh
```

**Windows** (PowerShell)
```powershell
iwr -useb https://raw.githubusercontent.com/gary23w/nl-veil/main/install.ps1 | iex
```

or by hand:
```sh
git clone https://github.com/gary23w/nl-veil && cd nl-veil
zig build run
```
The `veil` binary (Zig) and the neuron-db memory engine (Rust) are built for you on first run — each
with a prompt before it downloads anything. Point `--neuron-bin` / `--bin` at existing binaries to
skip the builds.
</details>

## Start it

`veil` **is** the launcher and the control plane. Run it with no subcommand to start the app; add a
verb to drive the running server over its API.

```sh
veil                 # THE ONE-CLICK DEFAULT: starts the server AND opens the desktop app
veil --server-only   # server alone, no desktop (headless boxes, services, containers)
```

Closing the desktop window shuts the whole thing down — server and everything it spawned — so there's
no stray process left listening. On Windows a double-click opens no console window; run it from a
terminal and your terminal is left alone.

Point the model endpoint with `NL_LLM_BASE_URL` / `NL_LLM_MODEL` / `NL_LLM_KEY` (it defaults to a
local Ollama), or pick a model in the web UI / the desktop. On a localhost bind the server mints an
admin key at `data/.desktop_key`; the CLI and the desktop read it automatically, so same-machine
commands never prompt for auth. **Any `veil <verb>` auto-starts the server if it isn't already up.**

**Where your stuff lives:** a `data/` folder **next to the `veil` binary** — conversations, memory,
swarm workdirs, logs, all of it. Nothing is written to a system temp dir and nothing leaves the
machine. Move the folder and you move the whole install; back it up and you've backed up everything.
(From a source checkout it resolves to the repo's own `data/`, so dev and release never share state.)

## The `veil` command line

Every subcommand is a thin client over the running server's `/api/v1/*` — no second control plane, no
argv secrets, no Python. The verbs:

```
veil                          start the app: server + desktop (--server-only for headless)

SWARMS
  cast "<goal>" [flags]        deploy a swarm to work a goal
      --minutes N  --minds N  --model M  --provider P  --base-url U  --key K
      --style S  --name N  --continuous  --offline  --follow
  deploy "<goal>" [flags]      alias for `cast --continuous` (a sustained hive)
  list | ls                    list your swarms
  stop <id>                    ask a swarm to stop
  rm <id>                      stop and remove a swarm
  events <id> [--follow]       stream a swarm's event log

CHAT (the server-side veil brain)
  chat [conv]                  interactive REPL; a line typed mid-turn steers the running turn

SCHEDULED TASKS (admin-gated)
  sched list
  sched add --name N --prompt "..." [--kind once|every|daily] [--every MIN] [--at HH:MM]
  sched run <id>               run a task now
  sched rm <id>                delete a task

FLEET
  hub                          roster: fleet summary + every swarm's state
  hub all "<text>"             broadcast a directive to every swarm
  hub stopall                  stop every swarm

MISC
  doctor                       check server + token health
  version | help
```

Cast in one line and watch it work:

```sh
veil cast "Build a CLI todo app in Python with tests" --follow
veil deploy "Keep researching fusion power and brief me each pass" --style discourse
veil cast "add a search box to my landing page" --offline
```

## The chat brain runs in the server

The agentic chat loop — planning, tool-calling, streaming, steering, and memory — runs **server-side**
in [`src/worker/chat/engine.zig`](https://gary23w.github.io/nl-veil/#doc=worker/chat/engine). Clients
(`veil chat`, veil-desk) are thin: they speak three REST calls per conversation.

```
POST   /api/v1/chat/convs/:id/messages          # send a message → runs one server-side turn
GET    /api/v1/chat/convs/:id/events?from=<n>    # stream the turn's event frames from a byte cursor
POST   /api/v1/chat/convs/:id/control            # {"op":"steer","text":...}  or  {"op":"stop"}
```

One turn runs per conversation. While it's working, a line you type becomes a **steer** the running
turn folds in without restarting; `stop` ends it. The turn writes its progress into the conversation's
own store (`messages.jsonl` + `events.jsonl`), which is exactly what the event stream serves — so every
client sees the same turn, live. The desktop **prefers this backend and falls back** to a bundled local
engine if it's disabled (`VEIL_CHAT_BACKEND=0`) or unreachable. `veil chat` opens a terminal REPL over
the same three calls:

```
$ veil chat
veil chat — conversation cli7f3a1c
  type a message; while the veil is working, a line STEERS the running turn.
  /stop  interrupt the current turn   /new  fresh conversation   /quit  leave

> what are you working on?
```

## Scheduled tasks

A scheduled task runs **strictly through chat**: when it comes due, the server mints a fresh
conversation named `scheduled_*` and fires **one ordinary chat turn** at it — so a run persists, streams
its events, shows up in the conversation list, and can be continued by hand afterwards. Manage them with
`veil sched` (admin-gated):

```sh
veil sched add --name nightly --prompt "summarize today's repo changes" --kind daily --at 22:00
veil sched add --name watch   --prompt "check the build and report" --kind every --every 30
veil sched list
veil sched run <id>          # fire it now → prints the conversation it created
veil sched rm <id>
```

Kinds are `once` (fires at a set time), `every` (`--every MIN`), and `daily` (`--at HH:MM`, on your
local wall clock). An overdue task — server was down, laptop asleep — runs **once** on wake and
reschedules from now; it never backfills a run per missed interval.

## Log in with Cloudflare (Workers AI)

Instead of pasting a Cloudflare API token, a user can grant Workers AI access once through the browser.
In the desktop **Settings**, pick the Cloudflare provider and click **Log in with Cloudflare**: the
system browser opens Cloudflare's consent page, and on grant the server exchanges the code
(Authorization Code + **PKCE**, a public client — no secret), resolves the account, and keeps the token
(auto-refreshed) in the server's sealed vault. Chat and casts then run Workers AI with no pasted key.
The manual account-id + token fields stay as a fallback.

This uses Cloudflare's **self-managed OAuth clients**, so a deployment registers its own client once:

1. In the Cloudflare dashboard: **Manage Account → OAuth clients → Create client**. Choose **Public
   client (Authorization Code + PKCE)**, allow **localhost** redirect URIs, and add the redirect
   `http://localhost:8787/api/v1/oauth/cloudflare/callback` (match your `NL_PORT`). Select the scopes
   your app needs — at least account read, Workers AI, and offline access (a refresh token). The exact
   scope strings are shown in the dashboard's scope picker (or `wrangler login --scopes-list`).
2. To let **any** user log in to their **own** Cloudflare account, verify ownership of the client's URL
   domain and make the client public; a client used only within your own account needs no verification.
3. Point the server at the client — only the public `client_id` is baked in:

```sh
NL_CF_OAUTH_CLIENT_ID=<your-public-client-id>          # required; the feature is off until set
NL_CF_OAUTH_SCOPES="account:read ai:write offline_access"   # override to match your client's scopes
# optional overrides (sane defaults shown):
NL_CF_OAUTH_REDIRECT=http://localhost:8787/api/v1/oauth/cloudflare/callback
NL_CF_OAUTH_AUTH_URL=https://dash.cloudflare.com/oauth2/auth
NL_CF_OAUTH_TOKEN_URL=https://dash.cloudflare.com/oauth2/token
```

The flow is exposed as `POST /api/v1/oauth/cloudflare/start` (returns the consent URL), the browser
callback `GET …/callback`, `GET …/status`, and `POST …/logout`. The token is stored per user and never
returned to the client; the desktop only ever sees the connection status + account id.

## The desktop — veil-desk

`veil-desk` is a native desktop dashboard (Zig + raylib, one window, no browser) that talks to the
local server. It's where most people actually live: a **chat pane** with the Veil, a **swarm board**
that shows every running hive round-by-round, and a **build console**.

- **Talk and it acts.** The chat pane is a **thin client over the server-side brain**: your message
  runs one server turn, the answer streams back, and you can steer or stop it live. Ask it to *build*
  something and the turn casts a hive, watches it, and folds the deliverables back into the
  conversation — with an **auto-loop** tier (armed from the desk, driven server-side) that keeps a long
  build moving without you re-prompting each round.
- **You see everything.** Live per-round fitness, the files each mind is writing, the tool calls, the
  shared-memory writes — swarm work is transparent, not a spinner.
- **It sits in the tray.** A system-tray icon and native toasts on Windows; it lights up the moment
  the server has something to show.

The desktop is compiled **into** `veil`, so the released binary is the whole app — double-click and
you're in, server and window together. Same from source:

```sh
zig build run                 # server + desktop, exactly like the release binary
zig build -Dapp=false         # server-only build: no GUI compiled in, no raylib/GL to link
```

`-Dapp=false` is what headless hosts and CI boxes want — the GUI is left out of the compilation
entirely rather than merely unused. To keep the GUI compiled in but not opened for a given run, pass
`--server-only` at runtime.

## It learns

The engine keeps a **playbook**: fixes it discovered by actually running commands on *this* machine.
When a command fails and a later command in the same arc succeeds, that verified fail→fix transition
is captured — *never* from the model's self-report, only from real exit codes — and recalled into
future prompts, gated so only a lesson genuinely relevant to the current failure surfaces. The same
fix stops being re-derived every session.

That's one thread of a broader self-improvement loop, all built on verified traces rather than the
model's own claims:

- **A progress checkpoint**, rebuilt every round from the run's own tool records — what completed,
  what's blocked, what's still pending — injected back into each mind's prompt with zero model calls.
- **A background review pass** that reads the round's real tool trace out-of-band and mints
  trace-grounded lessons and skills into the live hive.
- **A smoke gate** that boots the deliverable and probes it, because passing tests are not a working
  app — and a **judge** that grades the arc's ground-truth trace, not its self-narrative.
- **Strengthen-only plasticity**: outcome feedback can reinforce a memory that keeps working, but it
  can never *mint* one from a reward alone — so a finished goal can't be resurrected by its own signal.

The engine stays a fixed floor. What it learns lives in memory, never in an `if` branch.

## Your AI's sub-agent — cast a hive from another assistant

The hive is also a **side agent for whatever AI you already talk to**. Any assistant that can run a
shell command can hand off a research question or a side-build, keep working, and pull the progress and
deliverables from the swarm's event stream instead of grinding through it in its own context window:

```sh
# start it and follow the stream to completion
veil cast "why does saving a note drop the last line? recommend a fix" --follow

# or start it, keep chatting, and tail it later
veil cast "research WASM memory models and write a brief"
veil events <id> --follow
```

Casts made this way run detached, stay bounded (`--minutes` / `--minds`), never post publicly, and are
graded by the engine's own smoke gate and judge. A dedicated **MCP bridge** — wiring the hive in as
tools a chat client calls directly — is **planned but not yet built**; there is no `veil mcp` command
today, so drive it as a shell command for now.

## How it works

Three pieces, each its own repo, that snap together:

```
  ┌─────────────────────────────────────────────────────────────┐
  │  the veil  (this repo)   the swarm engine + the Veil + CLI   │
  │     │                                                        │
  │     │  every turn: perceive → recall → act → imprint         │
  │     ▼                                                        │
  │  neuron-db               the hive's memory  (one `neuron` bin)│
  │     ▲                                                        │
  │     │  bulk-load clean facts; scouts fetch pre-cleaned docs  │
  │     │                                                        │
  │  nl-rag                  the knowledge substrate (doc packs) │
  └─────────────────────────────────────────────────────────────┘
```

**the veil** — the engine. Each mind runs a *moment loop*: it perceives the goal and live state,
recalls what the hive knows, acts (write a file, search, run tests, edit, message a peer), and
imprints what it learned back into memory. Periodically the hive is integrated into the Veil — a
single self (*I am / I know / I have / my will*) that persists across runs, answers you, and folds
your intent into the next move. The engine is a fixed floor; **behaviour emerges from live signals**
(the mode, the plan, the strategy), never from hardcoded use cases.

**[neuron-db](https://github.com/gary23w/neuron-db)** — the memory. A small associative store
compiled to one `neuron` binary the engine calls for every recall and observe. It's what makes the
loop an *oscillation*: perception becomes graph, reasoning becomes graph traversal, and each
prompt is rebuilt from a trust-weighted recall instead of carried as flat text — so a small local
model gets a large-model floor to stand on, cheaper in tokens and richer in context. Fetched and
built for you on first run (needs [Rust](https://rustup.rs)); reused after that.

**[nl-rag](https://github.com/gary23w/nl-rag)** — the knowledge. A curated repository of canonical
documentation (languages, web, databases, security, ops…) pulled and normalized into clean,
frontmattered markdown *packs*, each with a `pack.facts` file. The veil's compiled-in source atlas
points scouts at these packs first, so a small model reads pre-cleaned markdown instead of fighting
HTML — and you can bulk-load a pack straight into hive memory:

```sh
neuron import packs/rust/pack.facts --scope knowledge     # from a cloned nl-rag
```

Optionally, **hyperspace grounding** (`NL_HYPERSPACE=1`) settles the most relevant memory into a
warm in-RAM field before each call, so a typical round does *zero* database subprocess calls for
grounding. It's bounded (~45 KB/mind) and scales down to an IoT profile (`NL_HYPERSPACE_CAP=48`).

## What you can do

The same binary covers very different jobs — the **mode emerges from your words**:

- **Build software, graded by its own tests.** The hive plans a file tree, splits the work, writes
  the project, runs the tests it wrote, and folds the results into its fitness — it keeps going
  until the deliverable actually passes. `veil cast "Build a URL shortener with a REST API and tests" --follow`
- **Research & brief.** In `--style discourse` the minds research the live web, form and argue
  their own views, and co-write a briefing. `veil cast "Brief me on fusion power in 2026" --style discourse`
- **Operate a live device.** Point the Veil at a device that drops telemetry on a file bus and it
  acts to keep it healthy, graded by an **acceptance oracle** — the device's own measured health,
  which the Veil never sees and can't write, so only a real fix moves the number. The shipped
  example is a self-healing security daemon (detect → remove persistence → block C2 → verify);
  swap the corpus and telemetry, not the code, for any device. See
  [`examples/embedded/`](examples/embedded/). `veil deploy "Keep this device healthy"`
- **Offline knowledge appliance.** `--offline` removes every web tool; a `corpus` in the run's
  manifest preloads knowledge (an nl-rag pack, say) into memory. A sealed appliance that reasons only
  over what you chose. `veil cast "Answer only from what I preload" --offline`

## Configuration

Each run has a `swarm.json` manifest — the web UI and the desktop write it for you, or hand-write it:

| field | meaning |
|---|---|
| `provider` / `model` / `base_url` | the LLM endpoint (any OpenAI-compatible API) |
| `minds` | the roster of named minds |
| `minutes` | auto-stop after N minutes (`0` = until stopped) |
| `style` | `auto` · `build` · `discourse` · `investigate` · `debate` |
| `internet` | `false` runs fully offline |
| `corpus` / `corpus_cap` | a `.facts`/`.jsonl` pack to preload, and how many facts |
| `gateway_model` | optional cheaper/smaller model for mechanical calls (and the chat's fast voice) |

**Endpoint resolution**, everywhere: a run's own `swarm.json` › `NL_LLM_*` env › `~/.veil/config.json`
› local defaults. **Secrets never go in `swarm.json`** — use `NL_LLM_KEY` in the environment or a
gitignored `keys.env` in the run dir.

> **A note on local-model latency.** On a single-GPU box, a running hive and the chat share one
> model queue, so the Veil's voice can wait behind a generation. Fixes, best first: set
> `OLLAMA_NUM_PARALLEL=2` (share the loaded model), give the chat a **tiny** side model via the
> manifest's `gateway_model`, or use a **hosted endpoint** — which answers the hive and the chat
> concurrently and sidesteps the whole issue.

## Web control plane

The same binary serves the **web app**: chat with the veil, watch swarms, run scheduled tasks, browse
what a turn built, and manage accounts — the desktop's surfaces, in a browser, on any device on your
network. It comes up whenever the server runs:

```sh
zig build && ./zig-out/bin/veil      # serves http://127.0.0.1:8787
```

First-run local login is `admin@neuron-loops.local` / `changeme` — **change it immediately** via
`NL_ADMIN_EMAIL` / `NL_ADMIN_PASSWORD`. On a public bind (`NL_BIND` ≠ `127.0.0.1`) the server
refuses the default and prints a generated password once.

### Everyone else is sandboxed

**Set the default model in the Admin tab.** Pick it from the same catalog the Settings tab uses; it
applies immediately, with no restart, to everyone who has not chosen their own. The API key is never
part of it — each account still supplies its own, sealed server-side. Without a default, a brand-new
account has to configure a model before it can chat at all.

The web app is multi-user, and **a normal account is not trusted with the host**. Its turns run a
restricted tool surface: the conversation's own workspace, research, and the *entire* hive-memory
surface — but no code execution, no host commands, no engine self-modification, no tool authoring, no
browser or MCP drive, and no casting swarms or scheduling runs (both execute outside the sandbox).
The admin account keeps the full surface. Files were always confined to the conversation's workdir;
what changed is that the dangerous verbs are now refused inside a turn, not just on the tool endpoint.

| variable | what it does |
|---|---|
| `NL_MAX_TURNS` | how many chat turns run at once, server-wide (default 64, ceiling 256). Size it to the rate limit of the provider key everyone shares |
| `NL_MAX_TURNS_PER_USER` | how many of those one account may hold (default: an eighth of capacity). This is what stops one busy user starving everyone else |
| `NL_KEEPALIVE_REQUESTS` | requests one connection serves before recycling (default 200). Drop to 1 if you hit a stuck-socket worker thread |
| `NL_DEFAULT_MODEL` / `NL_DEFAULT_BASE_URL` | **seeds** the default model on a fresh install, for unattended provisioning. Afterwards set it in **Admin → Default model** — that persists to `data/server-config.json` and wins over the environment, so a stale launch script cannot undo the admin on the next restart |
| `NL_OPEN_REGISTRATION` | let people sign themselves up. Off by default; the admin creates accounts from the Admin tab instead |
| `NL_BROWSER_DRIVER` / `NL_MCP` | give **sandboxed** users the browser / local MCP servers too. Admins already have both; leave these unset unless you mean it — the browser inherits this machine's network position and its profile's cookies |

Provider keys are entered per model in Settings and sealed server-side per account. They are never
stored in the browser, and the server never sends one back — only a last-four and a fingerprint.

## The fleet hub — many swarms, one console

The web control plane watches *one* box, one swarm at a time. `veil hub` is a **fleet console** over
the same running server: because the server already aggregates every swarm you own, the console is
API-backed and honest — no second, out-of-band control plane.

```
veil hub                     # roster: fleet summary + every swarm's state
veil hub all "<text>"        # broadcast a directive (say) to EVERY running swarm
veil hub goal "<text>"       # set a new goal on every swarm
veil hub stopall             # fleet-wide kill switch (a safety stop for autonomous minds)
```

**Cross-machine aggregation** — many *machines* meshed into one roster, the way the old `hub.py`
worked — is a **planned server endpoint**, intentionally left as a documented follow-up rather than a
second control plane. Today the console operates the local server's fleet.

## Project layout

```
install.sh  install.ps1    one-command installers (no Python)
scripts/                   the release build scripts (build-release.sh / build-release.ps1)
veil  veil.cmd             the `veil` front-door shim → the compiled binary
build.zig                  the Zig build (server + CLI + desktop; -Dapp=false = server-only)
src/
  main.zig                 entry point: CLI dispatch, then the server + control plane (auth, routes)
  cli.zig                  the `veil` CLI — a thin client over the server's /api/v1/*
  cli/{chat,hub}.zig       the interactive chat REPL and the fleet console
  gateway/http.zig         the HTTP surface: App context, the auth guard, JSON/file helpers
  auth/  config/  admin/   accounts + API keys, the encrypted key vault, the admin API
  worker/                  the hive and the server-side brain:
    chat/{engine,service,tools,context,plan}.zig  the chat brain — the agentic turn loop, its REST
                                                   handlers, tools, context window, and plan board
    sched.zig              scheduled tasks (each run is a server chat conversation)
    control/{supervisor,writer,fanout}.zig  swarm processes, the control bus, event streaming
    deploy/service.zig     the cast/deploy door + swarm files, bundle, archive, lifecycle
    neuron/client.zig      the neuron-db memory bridge (fail-open)
    run.zig  agi.zig  oscillation.zig  rsi.zig  vcs.zig  tools.zig  writer.zig …  the moment loop,
                                                   the Veil, the self-improvement faculties, the
                                                   micro-VCS for concurrent minds
    locs/atlas.zig         the source atlas — points scouts at nl-rag packs
desk/                      veil-desk, the native desktop dashboard (its own build.zig + raylib)
docs/                      the annotated-source case file (a static site, home-built md parser)
examples/embedded/         the device-operator worked example
web/public/                the bundled control-plane UI
bin/neuron[.exe]           the neuron-db memory engine (bundled / built on first run)
```

## Release

Builds ship on the [Releases page](https://github.com/gary23w/nl-veil/releases/latest), one per
platform. Unzip and run `veil` — that starts the server **and** opens the desktop app. No Python, no
toolchain, no first-run build; the memory engine ships inside.

| asset | what it is |
|---|---|
| `veil-…-windows-x86_64.zip` | **the app** — Windows |
| `veil-…-macos-arm64.zip` / `…-macos-x86_64.zip` | **the app** — Apple Silicon / Intel |
| `veil-…-linux-x86_64.zip` | **the app** — Linux |
| `veil-server-…-<os>-<arch>` | **server only**, no desktop — headless hosts, containers, remote boxes |
| `SHA256SUMS-*.txt` | checksums |

Desktop builds are produced natively per-OS (the GUI links the platform graphics stack and can't be
cross-compiled); the standalone server cross-compiles to every target from one runner.

To cut your own, the official builder wraps the whole thing and **bootstraps its own toolchain** — a
missing Zig, Rust, C compiler, or (on Linux) raylib dev library is fetched for you first:

```sh
sh scripts/build-official.sh              # everything for this host, plus cross-built servers → bin/
sh scripts/build-official.sh --host-only  # skip the cross-compiled server matrix
```

It stages into a private prefix, so it never disturbs `zig-out` — you can cut a release while the app
is running. `NO_BOOTSTRAP=1` skips the dependency step (supply `ZIG=` / `NEURON=` yourself).
`veil doctor` prints server + token health.

## License

[MIT](LICENSE). Use it, fork it, build on it.
