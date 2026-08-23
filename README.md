![the-veil](web/public/veil.png)

# the veil

<sub>NEURON-LOOPS · NL-VEIL — **an agentic coding desktop app that runs a whole team of AI agents on your machine, and remembers.** One binary, many minds, one shared memory. Browse the annotated source of every module at [the docs site](https://gary23w.github.io/nl-veil/).</sub>

<p>
  <a href="https://github.com/gary23w/nl-veil/actions/workflows/release.yml"><img alt="build" src="https://github.com/gary23w/nl-veil/actions/workflows/release.yml/badge.svg"></a>
  <a href="https://github.com/gary23w/nl-veil/releases"><img alt="release" src="https://img.shields.io/badge/release-v1.0.1--beta--6-A8241B"></a>
  <img alt="zig" src="https://img.shields.io/badge/zig-0.16-F7A41D?logo=zig&logoColor=white">
  <a href="https://huggingface.co/gary23w/the-veil-12b"><img alt="built-in model" src="https://img.shields.io/badge/built--in%20model-the--veil--12b-6E4A27?logo=huggingface&logoColor=white"></a>
  <a href="https://huggingface.co/gary23w/gary-neuron-emergent"><img alt="memory cortex" src="https://img.shields.io/badge/cortex-gary--neuron--emergent-6E4A27?logo=huggingface&logoColor=white"></a>
  <a href="https://github.com/gary23w/neuron-db"><img alt="memory" src="https://img.shields.io/badge/memory-neuron--db-31405C"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-31405C"></a>
  <a href="https://github.com/gary23w/nl-veil/stargazers"><img alt="stars" src="https://img.shields.io/github/stars/gary23w/nl-veil?style=social"></a>
</p>

### What this actually is

**A desktop app for agentic coding, called the Veil.** You download one file, run it, and a native
window opens: a three-pane workspace where you give an AI a goal and watch it do the work. Your
conversations down the left, the work itself in the middle — the chat, or the files it is writing, or
live token and latency metrics — and on the right what the agents are doing and what the thing
remembers. Drag the dividers to whatever widths suit you (they persist), collapse a side you don't
need, branch a side question into its own tab without losing the build. Six tabs across the top:
**Dashboard, Chat, Swarm, Hub, Tasks, Settings.** It is the place you work, not a sidebar bolted onto
something else.

**The difference is what's behind the window.** Ask most tools for a feature and one assistant writes
it. Ask the Veil and it can **split the job across a swarm** — a handful of specialist agents, each
owning real files, building and critiquing in parallel against one shared workdir with its own
version control, reconciled back into a single answer. You talk to one voice; a team is doing the
work behind it.

**And it remembers.** Not chat history — a memory engine that accumulates what it learns about your
code and your preferences, keeps a playbook of fixes it has *verified* by running commands on this
machine, and carries all of it into the next session. The same problem stops getting re-solved.

**Nothing to set up, and nothing leaves.** One Zig binary carries the whole thing: the desktop app,
the server behind it, a web UI, the inference engine, the memory engine, and the `veil` command line.
No Python, no Node, no Docker, no cloud account, no database service, no API key — it will
**[download a 12B model](https://huggingface.co/gary23w/the-veil-12b) and run it itself**, offline, on
your GPU. Point it at Ollama or any OpenAI-compatible endpoint instead whenever you'd rather. Your
code, your keys and everything it learns stay in a folder next to the binary.

> ⭐ **If the veil is useful to you, [star it on GitHub](https://github.com/gary23w/nl-veil).** It's a
> solo project — a star genuinely helps it reach the next person who'd get something out of it.

**What's in it now**

| | |
|---|---|
| [**The built-in model**](#the-built-in-model--nothing-to-install) | `the-veil-12b` served in-process from a downloaded GGUF — no external runtime, no key, works offline |
| [**The chat brain in the server**](#the-chat-brain-runs-in-the-server) | one agentic turn loop, server-side; the web app, the desktop and `veil chat` are thin clients of it |
| [**The model trio**](#three-models-one-turn--the-model-trio) | every LLM call is labelled and routed — coding / thinking / prompting — so a cheap model can carry the bulk |
| [**Your own browser**](#it-can-use-your-browser) | drive the Chrome/Edge you're already signed into, through a tiny extension — or a private throwaway profile |
| [**The tool belt**](#the-tool-belt) | ~58 tools: files, shell, tests, web, deep crawl, memory, images/OCR, MCP servers, tool authoring |
| [**Memory that compounds**](#how-it-works) | [neuron-db](https://github.com/gary23w/neuron-db) behind every recall, with `--lineage` so re-casts get better |
| [**Built-in RAG**](#what-you-can-do) | mirror the [nl-rag](https://github.com/gary23w/nl-rag) corpus to disk and research with the network off |
| [**It learns**](#it-learns) | a playbook of fixes verified by real exit codes, a smoke gate, and a judge that reads the trace |
| [**Themes & plugins**](#make-it-your-own--themes--plugins) | Lua, hot-reloaded, across web + desktop + CLI ([PLUGINS.md](PLUGINS.md)) |
| [**Scheduled tasks**](#scheduled-tasks) · [**the desktop**](#the-desktop--veil-desk) · [**the fleet hub**](#the-fleet-hub--many-swarms-one-console) | cron-ish runs that are real conversations, a native dashboard, one console over every swarm |

Browse the annotated source of every module at **[the docs site](https://gary23w.github.io/nl-veil/)**
(`docs/`) — an interactive architecture map and ~100 generated source documents, in the same design
system the desktop app compiles in.

## One server, three faces

The mental model, because everything else follows from it: **the server process is the whole system.**
It holds the accounts, the memory, the model keys, and it is the only thing that executes tools. The
web app, the desktop window, and the CLI are all just clients of the same `/api/v1` surface — none of
them holds state the others can't see.

```
                    ┌──────────────────────────────────────────────┐
   a browser,  ───►  │  veil  (ONE process, ONE binary)              │
   any device        │                                              │
                     │   http :8787   ──►  route table (main.zig)   │
   the desk    ───►  │                       │                      │
   window            │                       ▼                      │
                     │                  /api/v1/*                   │
   `veil <verb>` ──► │       accounts · memory · sealed keys ·      │
                     │       swarms · scheduled tasks · TOOLS       │
                     │                       │                      │
                     └───────────────────────┼──────────────────────┘
                                             ▼
                                   this machine's disk,
                                   shell, network, models
```

**(a) The web app.** `web/public/{index.html,app.js,styles.css,models.json}` — no bundler, no build
step, no framework. `index.html` is a single `<div id="app"></div>`; the entire UI renders from
`app.js`. The four files are embedded into the binary at compile time (`build.zig:71-74`) and served
by `staticIndex` / `staticJs` / `staticCss` / `staticModels` (`src/main.zig`, the route table). Tabs:
**Dashboard, Chat, Tasks, Swarms, Admin** (admins only), **Settings**.

**(b) The desktop window.** `desk/*.zig`, compiled **into the same binary** via `-Dapp` (default true,
`build.zig:82`). In app mode the GUI runs on the main thread and the HTTP server on a background
thread (`src/main.zig`, "APP MODE") — one process, no child to spawn, no second executable in the
bundle.
raylib is a *lazy* dependency, so `-Dapp=false` never fetches it at all.

**(c) The CLI.** `src/cli.zig` dispatches every verb over HTTP to the running server
(`src/cli/{chat,hub}.zig` for the two big ones). There is no second control plane and no argv secrets.

### Why that shape matters to you

- **Your phone gets the same app as your desktop**, and nothing is installed on the phone. It's a URL.
- **The tools run on the host machine, not in the browser.** A browser can't execute a shell command,
  so the server does it — `web/public/app.js` deliberately omits the `tool_client` flag for exactly
  this reason (see the comment in `sendTurn`), and the turn's tools run server-side through
  `POST /api/v1/chat/tool`. When you ask the veil in a browser to write a file, the file lands on the
  machine running `veil`.
- **Accounts are isolated on disk.** Each user's data lives under `{data}/u{uid}/…`, and non-admin
  accounts run a restricted tool surface (`src/worker/chat/tools.zig`, `toolSafe` / `chatTool`). See
  [everyone else is sandboxed](#everyone-else-is-sandboxed).
- **One provider key can serve everyone**, or everyone can bring their own. That choice is yours and
  it has a real cost — see [the shared provider key](#the-shared-provider-key).

## Install

**Download it and run it — no toolchain, nothing to build.** Grab your platform's bundle from the
**[latest release](https://github.com/gary23w/nl-veil/releases/tag/v1.0.1-beta-6)**, unzip, and run `veil`:

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

> **Beta builds are unsigned.** Windows shows *"Windows protected your PC"* → **More info → Run
> anyway**. macOS says the developer can't be verified → **right-click → Open** (or
> `xattr -dr com.apple.quarantine <folder>`). Signing certificates are still on the list.

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

> **It listens on every network interface by default.** `NL_BIND` is unset → the server binds
> `0.0.0.0`, which means anyone who can reach this machine on port 8787 can open the login page
> (`src/main.zig:427-439`). That is the point — a phone on the sofa should be able to open it — but
> it is worth knowing before you leave it running on a café wifi. `NL_BIND=127.0.0.1` pins it to this
> machine only. See [the walkthrough](#walkthrough-run-it-add-people-put-it-on-your-network).

**About models:** you don't have to bring one — download the built-in `the-veil-12b` in the app (or
`veil model pull`) and it serves itself, [see below](#the-built-in-model--nothing-to-install). To use
something else, point the endpoint with `NL_LLM_BASE_URL` / `NL_LLM_MODEL` / `NL_LLM_KEY` (a local
Ollama is the fallback default), or just pick a model in the web UI / the desktop. The server
**always** mints an admin key
at `data/.desktop_key`; the CLI and the desktop read it automatically, so same-machine commands never
prompt for auth. It is a file readable only by your OS user — opening the port to the LAN does not
make a local file more reachable. **Any `veil <verb>` auto-starts the server if it isn't already up.**

**Where your stuff lives:** a `data/` folder **next to the `veil` binary** — conversations, memory,
swarm workdirs, logs, all of it. Nothing is written to a system temp dir and nothing leaves the
machine. Move the folder and you move the whole install; back it up and you've backed up everything.
(From a source checkout it resolves to the repo's own `data/`, so dev and release never share state.)

## The built-in model — nothing to install

Most local-AI setups start with a second program: install a runtime, pull a model, keep it running,
point the app at it. **veil skips that.** The inference engine is compiled into the binary, and the
server serves **[the-veil-12b](https://huggingface.co/gary23w/the-veil-12b)** itself from a GGUF on
disk. There is no runtime to install, no port to keep alive, no key to paste.

The weights are the only thing not in the download (a model is bigger than an app), so the first run
offers to fetch them:

```sh
veil model status              # weights + engine + any download in flight
veil model pull                # download the published weights — resumable, sha256-verified
veil model import [--path F]   # copy a GGUF you already have (no --path: find your local runtime's copy)
veil model check               # is a newer release published? (compares shas; `pull` installs it)
veil model cancel              # stop the running pull — the partial resumes next time
veil model rm                  # remove the serving weights
```

In the desktop there's a panel for the same thing: a **download** button, a live progress bar, and
one click to make it the active model. A finished download **hot-swaps** into the running server —
no restart. An install manifest beside the weights records what is installed and how it arrived, so
`check` can tell "you have the current build" apart from "you have something you imported".

- **It runs on your GPU when you have one.** The Vulkan backend is compiled in and the loader is
  opened at run time, so a machine with no GPU falls back to CPU cleanly rather than failing to
  start. (`-Dvulkan=false` cuts ~50 MB of embedded shaders from the binary; macOS builds are CPU-only
  until a Metal tier exists — Apple silicon's unified memory carries it.)
- **The engine endpoint is not an open local port.** It is loopback-only and every request carries a
  bearer minted fresh at boot, so other processes on the machine can't quietly use your model the way
  they can with a conventional runtime.
- **It is one provider among the others.** Pick `builtin` in Settings, or keep Ollama, or a hosted
  endpoint, or a different model per role — see [the model trio](#three-models-one-turn--the-model-trio).
- **You can leave it out.** `zig build -Dbuiltin=false` never even fetches the inference sources; the
  builtin provider then simply reports itself unavailable and everything else works as before.

> **The engine is tuned for small local models, not just big hosted ones.** A model at or below ~24B
> (or with a ≤15k window) gets a **compact tool belt** and a tighter doctrine — fewer verbs to rule
> out per call, no delegation concepts, honest "I can't read that" answers instead of fumbled
> fetches. Capability isn't removed: the full tool schema still dispatches if the model calls it.
> For local Gemma-4 the engine also renders the prompt itself rather than going through the runtime's
> template — verified byte-for-byte against the model's own chat template, which measured 27/30 on
> the harness drills against 18/30 through the runtime's renderer (`src/worker/gemma4.zig`).

### The belt manifest — why a smaller belt scores higher

A tool array is JSON, and on the compact tier it is still ~3 KB of nested schema sitting far behind
the conversation. Asked whether it has a browser, a 12B does not re-read that JSON — it answers from
impression. Observed live (`c6a751a54`): the model ran `list_dir` hunting for its browser tools *in
the filesystem*, read the empty directory as proof, and denied a browser it was holding.

So the compact tier appends one generated line naming the belt it was actually handed
(`beltManifest`, `src/worker/chat/engine.zig`) — every tool by exact name, plus a **WON'T, NOT CAN'T**
rule that separates declining by judgment from claiming a capability is absent. It is derived from
the final belt string after grants and plugin schemas merge, so it can never drift from what the
provider sees, and it is turn-stable so prompt-prefix caching still holds.

Measured on `the-veil-12b` over 110 held-out drills across five sets:

| serving configuration | score | invented tool names |
|---|---|---|
| 20-tool belt, full doctrine, no manifest | 92/111 — 82.9% | 6 |
| **17-tool compact belt + manifest + date stamp** | **97/110 — 88.2%** | **2** |

The trimmed belt and the shorter doctrine contribute alongside the manifest, so the 5.3-point gain
belongs to the combination. What points at the manifest specifically is the invented-name column —
naming the belt in prose removes the model's reason to guess — and the same comparison on a later
checkpoint moved invented names from 11 to 1. The counter-intuitive part is worth stating plainly:
**the smaller belt scored higher.** Fewer tools, described in words, beat more tools described only
in schema.

The manifest is deliberately **compact-tier only**. Frontier models read a 49-tool array without
help, and the line costs tokens on every turn; extending it upward would need its own measurement on
a large model rather than an assumption borrowed from a 12B.

## Walkthrough: run it, add people, put it on your network

Written for someone who is not a developer. **If you only want it on your own machine, stop after
step 5** — the rest is about letting other people in.

### 1. Download and unblock it

Grab the bundle for your OS from the [latest release](https://github.com/gary23w/nl-veil/releases/tag/v1.0.1-beta-6)
and unzip it somewhere you'll find again. Builds are unsigned, so:

- **Windows** shows *"Windows protected your PC"* → **More info** → **Run anyway**.
- **macOS** says the developer can't be verified → **right-click the `veil` file → Open** → **Open**.
  (Or `xattr -dr com.apple.quarantine <folder>` in Terminal.)

### 2. Run it

Double-click `veil.exe` (Windows) or run `./veil` (macOS/Linux). The desktop window opens and the
server comes up behind it.

**One rough edge, stated plainly:** on Windows, double-clicking from Explorer relaunches `veil`
without a console window (`src/main.zig`, `detachOwnConsole`) — which is what you want for an app, but it means
**the startup banner is invisible**, and the banner is where the network URL and the admin password
notice get printed. There is no log file to read it out of afterwards, and the desktop window does not
display the URL either.

So if you care about the banner, **start it from a terminal instead** — when a shell owns the console,
`veil` leaves it alone and prints normally:

```powershell
# Windows PowerShell, from the folder you unzipped into
.\veil.exe
```
```sh
# macOS / Linux
./veil
```

### 3. Find the URL

On startup the server prints one complete URL per address this machine answers on
(`src/main.zig:671-696`, using `src/config/lan.zig`):

```
neuron-loops 1.0.1-beta-1 on http://localhost:8787
    open from another machine (phone, laptop) at:
      http://192.168.1.42:8787
```

If you missed the banner, ask the OS for the address instead — `ipconfig` (Windows), `ifconfig` or
`ip addr` (macOS/Linux) — and use `http://<that-address>:8787`.

The port is **8787** unless you set `NL_PORT` (`src/main.zig:369-373`). It is the one place the port is
resolved, so the CLI and the server always agree.

### 4. Log in as the admin

The first run creates an admin account. Because the server is reachable on the network by default and
you did not choose a password, it **generates** one — and writes it to a file, because a banner you
never saw is not a delivery mechanism:

```
data/admin-password.txt
```

That file sits next to the binary, beside the data it protects. The password is **stable across
restarts** — the server reads it back rather than minting a new one each boot (`src/main.zig`,
`readAdminPassword` / `writeAdminPassword`).

- Default email: **`admin@neuron-loops.local`** (change it with `NL_ADMIN_EMAIL`).
- To pin your own password instead of using the generated one, set `NL_ADMIN_PASSWORD` before starting.
  Do that and no file is written — the password is the one you chose.

> The old shipped default `changeme` still exists as the seed literal, but you will only ever meet it
> on an explicit `NL_BIND=127.0.0.1` run, where nothing is generated because nothing is exposed.
> Change it anyway.

### 5. Pick a default model for the instance

Open the web app (or the desktop) and go to **Admin → Default model**. Pick from the same catalog the
Settings tab uses; it applies immediately, to everyone who hasn't chosen their own, with no restart.
It persists to `data/server-config.json`.

`NL_DEFAULT_MODEL` / `NL_DEFAULT_BASE_URL` **seed** this on a fresh install for unattended setups —
but once an admin sets it in the UI, the stored value wins, so a stale launch script can't undo it on
the next restart (`src/config/server_config.zig`).

**Without a default model, a brand-new account cannot chat until it configures one itself.**

---

*Everything below is about other people using it. If it's just you, you're done.*

---

### 6. The shared provider key

**Admin → provider key** (`POST /api/v1/admin/keys`). It is stored sealed in the same vault as
everyone else's keys, under a reserved uid 0 that no real account can hold
(`src/worker/chat/service.zig:30`, `:65-76`).

The trade is worth stating outright, because it is a billing decision:

- **Without it**, every new account has to bring its own API key in Settings before it can chat at all.
- **With it**, nobody needs a key — and **every user's turns spend your credit.** A user's own key
  always wins if they have one, so setting this never silently switches a paying account onto your
  bill. But everyone else is on it.

For a family or a LAN of people you know, that's exactly right. For anything wider, think about it
first, and size `NL_MAX_TURNS` to the rate limit of the key you just handed everyone.

### 7. Create accounts

**Admin → + New user** (`POST /api/v1/admin/users`). Enter an email and a password of **8–200
characters**, then hand the password over out of band — the server never shows it again. Account
creation is audited (who was let in, by whom, when).

Self-signup is **off by default**. `NL_OPEN_REGISTRATION=1` opens it, which is the wrong posture for a
box on a LAN and the right one if you're running something more public.

### 8. Other people connect

They type `http://<your-ip>:8787` into any browser — phone, tablet, laptop, whatever's on the same
network. Nothing is installed on their device. They get the same web app you do, minus the Admin tab.

### 9. The firewall (this is the step that fails)

**If step 8 does nothing — a spinner, a timeout, "can't reach this page" — it is almost certainly the
firewall, and the app will not tell you.** There is no firewall detection anywhere in the codebase, so
a blocked port looks identical to a wrong IP address from inside the browser.

- **Windows.** The first time `veil` binds a port, Windows Defender Firewall pops up *"Allow this app
  to communicate on these networks."* Tick **Private networks** and allow it. If you dismissed that
  prompt — or clicked Cancel — Windows silently remembers the block. Fix it in **Windows Security →
  Firewall & network protection → Allow an app through firewall → Change settings**: find `veil` in
  the list and tick **Private**. If it isn't listed at all, **Allow another app…** and browse to
  `veil.exe`.
- **macOS.** You may get *"Do you want the application to accept incoming network connections?"* —
  say **Allow**. Otherwise check **System Settings → Network → Firewall → Options**.
- **Linux.** Usually nothing blocks it, but if you run a firewall you'll need to open the port
  (`sudo ufw allow 8787/tcp` on ufw-based systems).

Two things to check before you blame the firewall: both machines are on the **same** network (guest
wifi is often isolated from the main one), and you used the LAN address from the banner, not
`localhost` — `localhost` on their phone means their phone.

### 10. Locking it back down

```sh
NL_BIND=127.0.0.1 veil       # this machine only; nothing on the network can reach it
```

`localhost` works too. Anything else — or leaving it unset — binds every interface.

### Before you put this on a network

Two limits you should know about before you hand out passwords.

**Traffic is plain `http://`.** There is no HTTPS in the server today. Logins, passwords, chat
contents, and API responses cross your LAN unencrypted, readable by anything else on that network. On
a home or office network you control, that is a normal trade. On shared or public wifi it is not.

**Tools run on the host machine.** Non-admin accounts are sandboxed: their turns get the conversation's
own workspace, research, and the full hive-memory surface — but no code execution, no host commands,
no engine self-modification, no tool authoring, no browser or MCP drive, and no casting swarms or
scheduling runs. What that means: **a normal user cannot run commands on your machine.** What it does
*not* mean: their work is still stored on your disk, still spends whatever provider key is in play,
and the **admin** account keeps the complete surface — so anyone who gets the admin password gets a
shell on the host, in effect.

**About exposing this to the open internet:** it's a different risk class from a home LAN, and this
document isn't going to hand you a port-forwarding recipe as if it weren't. Plain-http logins over the
public internet mean credentials in the clear; unsigned self-signup plus a shared provider key means
your billing is the attack surface. If you genuinely need remote access, put it behind something that
terminates TLS and authenticates first (a VPN or a reverse proxy you already trust) rather than
forwarding 8787 at the router.

## The `veil` command line

Every subcommand is a thin client over the running server's `/api/v1/*` — no second control plane, no
argv secrets, no Python. The verbs:

```
veil                          start the app: server + desktop (--server-only for headless)

SWARMS
  cast "<goal>" [flags]        deploy a swarm to work a goal
      --minutes N  --minds N  --model M  --provider P  --base-url U  --key K
      --style S  --name N  --continuous  --offline  --follow
      --lineage <id>           persist this swarm's memory under <id> so re-casts COMPOUND
  deploy "<goal>" [flags]      alias for `cast --continuous` (a sustained hive)
  list | ls | ps               list your swarms
  stop <id>                    ask a swarm to stop
  rm <id>                      stop and remove a swarm
  events <id> [--follow]       stream a swarm's event log  (aliases: logs, watch)

CHAT (the server-side veil brain)
  chat [conv]                  interactive REPL; a line typed mid-turn steers the running turn

BUILT-IN MODEL (the-veil-12b, served in-process — no external runtime)
  model status                 weights + engine + any download in flight
  model pull                   download the published weights (resumable, sha-verified)
  model import [--path FILE]   copy a GGUF you already have into the store
  model check                  is a newer release published? (`pull` installs it)
  model cancel                 cancel the running pull (the partial resumes later)
  model rm                     remove the serving weights

KNOWLEDGE (the local pack corpus — built-in RAG)
  rag status                   is a local knowledge mirror active, and where from
  rag sync --from <clone>      copy an nl-rag checkout into the app's data dir for offline RAG
      --tier atlas|facts|full  manifest only | +INDEX+distilled facts (default) | +every page
      --dest <dir>             sync somewhere else (e.g. vendor/nl-rag pre-build)
      --include-auto           also copy machine-grown packs (off-topic risk; off by default)
  rag ingest <file>            absorb a local book/doc/notes into the hive as recallable facts
      --scope S --name L --cap N --db <hive.sqlite>

SCHEDULED TASKS (admin-gated)
  sched list
  sched add --name N --prompt "..." [--kind once|every|daily] [--every MIN] [--at HH:MM]
  sched run <id>               run a task now
  sched rm <id>                delete a task

FLEET
  hub                          roster: fleet summary + every swarm's state
  hub all "<text>"             broadcast a directive to every swarm
  hub goal "<text>"            set a new goal on every swarm
  hub stopall                  stop every swarm

EXTENSIONS (themes + plugins — see PLUGINS.md)
  themes                       list every theme (built-in + user)
  themes <id>                  print one theme's full palette
  plugins                      list loaded plugins, their tools + state
  plugins reload               admin: rescan <data>/plugins + <data>/themes, hot-swap

MISC
  doctor [--runtime]           server + token health; --runtime folds the runtime ledgers in
                               (learned tool behavior, schedule fail-streaks, per-model usage)
                               and works with the server down
  desktop | desk               open the app window (like a bare `veil`, but detached)
  exec-tool <tool> [args]      run one hive tool directly, in this process
  local-host                   the per-machine daemon that owns stateful local resources
                               (browser sessions) — started for you on demand
  sync-manifest / sync-read    the file-sync side of a delegated turn
  version | help
```

Cast in one line and watch it work:

```sh
veil cast "Build a CLI todo app in Python with tests" --follow
veil deploy "Keep researching fusion power and brief me each pass" --style discourse
veil cast "add a search box to my landing page" --offline
```

## Make it your own — themes & plugins

veil is extensible without a rebuild. Drop a Lua file into your data directory and it works across the
whole product — web, desktop, and CLI:

- **Themes** (`<data>/themes/*.lua`) re-skin everything. The shipped `dark`, `light`, and `matrix` themes
  are seeded there on first run; copy one, change the `id` and a few of the 16 colors, and it appears in
  every client's theme picker. `mono_ui = true` renders the whole UI in the code font (that's how `matrix`
  gets its terminal look).
- **Plugins** (`<data>/plugins/<name>/plugin.lua`) add tools the AI can call, **policy** hooks that gate
  what runs, and **prompt** hooks that shape every turn — all in a locked-down Lua sandbox. You can also
  bridge an external MCP server so its tools become veil tools.

The complete, copy-paste authoring guide — the `veil.*` API, the hook reference, the sandbox model, and
templates for both — is in **[PLUGINS.md](PLUGINS.md)**.

```sh
veil themes            # every theme, built-in and yours
veil plugins           # loaded plugins, their tools and state
veil plugins reload    # admin: pick up changes with no restart
```

## The chat brain runs in the server

The agentic chat loop — planning, tool-calling, streaming, steering, and memory — runs **server-side**
in [`src/worker/chat/engine.zig`](https://gary23w.github.io/nl-veil/#doc=worker/chat/engine). Clients
(`veil chat`, the desk, the browser) are thin: they speak three REST calls per conversation.

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

What the model sees each turn is governed, not accreted: every context block (memory, tool digests,
corrections, plugin hooks…) bids into a [prompt workspace](https://gary23w.github.io/nl-veil/#doc=worker/chat/workspace)
with a fixed render order, per-channel byte budgets, and a **provenance receipt** on every admitted
block — and each turn's admit/drop record lands in `workspace.jsonl`, so "why did it say that" has a
queryable answer. Recalled memory arrives **scored** (numbers, not vibes), a fact that contradicts a
stored sibling arrives marked `[CONTESTED]` with both sides shown, and a sentinel-gated second model
audits doubtful memory before the answering model reads it — annotations only, nothing is silently
deleted.

## The tool belt

A turn is only as useful as what it can actually touch. The engine ships **~58 tools**, all executed
by the server on the host machine (never in your browser), all logged as event frames you can watch
live:

| group | tools |
|---|---|
| **Files & code** | `read_file` `write_file` `edit_file` `delete_file` `list_dir` `stage_file` `stage_delivery` |
| **Run things** | `host_command` `run_tests` `run_python` `host_status` `host_explore` `stop_process` `poll` `probe` |
| **Web & research** | `web_search` `web_fetch` `read_url` `fetch_json` `deep_crawl` `read_doc` `osint_scan` |
| **Your browser** | `browser_navigate` `browser_read` `browser_click` `browser_click_at` `browser_type` `browser_type_text` `browser_key` `browser_scroll` `browser_eval` `browser_console` `browser_network` `browser_close` |
| **Screen & images** | `pixel_capture` `pixel_ingest` `pixel_search` — screenshots and attached images become searchable text + regions, so a model that can't see gets the picture anyway |
| **Memory** | `observe` `recall` `recall_hive` `absorb` `journal` `share` `save_skill` `note_stance` |
| **Coordination** | `send_message` `ask_veil` `add_task` `complete_task` `propose_plan_change` |
| **Other AI apps** | `mcp_discover` `mcp_call` — find the MCP servers already configured on this machine (Claude Desktop, Cursor, VS Code) plus local AI runtimes, and call their tools as if they were veil's |
| **Self-improvement** | `make_tool` (author a new tool at run time) `set_directive` (write its own playbook) `propose_change` / `simulate_change` / `patch_system` (governed, trial-gated) |
| **Secrets** | `get_credential` — the broker hands over a named credential; the value never enters the transcript |

Two of these deserve a note. **`poll` replaces blind sleeping**: a bounded watch loop that samples a
file, URL, port, process, command, or swarm until it's done or the budget expires, so a long wait is
a chain of bounded polls instead of one guess. And **`stop_process`** exists because a turn that can
start a server must be able to end one — a Stop from you now reaches a blocking tool instead of
waiting for it to finish.

Non-admin accounts run a **restricted subset** (workspace files, research, and the whole memory
surface — but no shell, no browser, no MCP, no tool authoring, no casting). See
[everyone else is sandboxed](#everyone-else-is-sandboxed).

## It can use your browser

Research that hits a login wall is research that stops. So the veil can drive **the browser you are
already signed into** — your profile, your cookies, your sessions, and you sitting right there to
answer a verification prompt — through a deliberately tiny **Chrome/Edge extension** in
[`extension/`](extension/).

- **Load it once.** `chrome://extensions` → *Developer mode* → **Load unpacked** → pick `extension/`.
  It finds the local server itself, pairs over loopback only, and remembers the pairing across a
  server restart.
- **The extension holds no automation logic.** It relays debugger commands and posts back replies —
  that's all. Every snapshot, click heuristic and page model lives in the server, so the app can get
  smarter without you ever reinstalling the extension. Input arrives as *real* browser events, not
  the synthetic kind a content script is limited to.
- **Pairing is loopback-only.** A remote attacker can't pair because the request has to originate on
  the machine; the relay's blast radius is the tab it drives. The token is never logged.
- **Or don't use your browser at all.** With no extension the driver launches its own throwaway
  profile, logged out of everything — the private option, still there and still the default for
  unattended casts.
- **Reads describe what happened.** A click reports its effect, and form fields are read back and
  confirmed, so the agent stops re-reading the page to guess whether anything landed.
- **A page read is projected, never truncated.** Ordinary tool results get clipped head-and-tail, but a
  page state is a *ref table* — byte-offset elision deletes elements the model then cannot see, and
  nothing distinguishes a dropped ref from an absent one. Measured on a live 18,317-character read: from
  the clipped payload the model named a confidently **wrong** ref for the search box, one it would then
  have typed into. The projection keeps every interactive ref and drops the JSON boilerplate repeated
  once per element — 59% smaller and lossless in refs, so it is not a size/quality trade.
- **It is told what the page cannot tell it.** Navigating invalidates every ref, and typing into a
  `button` or `a` activates it instead of entering text; both are now stated in the tool descriptions.
  Elements the extractor has no label for are marked `(unlabelled)`, duplicates `(dup N)` — on one real
  compose page, 17 of 175 elements carried no label and eleven separate ones all read "More".

> **A note on the tool descriptions, because it cost a week.** A *browser logic bomb* is an instruction
> that is internally consistent and locally reasonable, and from which a correct model derives that the
> task is impossible. `browser_navigate` said "a login-walled dashboard — reach for this"; `browser_type`
> said "never type credentials". Valid conclusion: *I cannot get in.* The model then defended it by
> denying it had a browser at all, reciting its own tool list back as proof of absence. Three fixes lost
> that argument before anyone checked the premise, and deserved to — on the belt as written, the model
> was right. The browser is the user's own and already signed in; that was simply never stated. **Tool
> descriptions are not documentation. They are the model's model of reality, and a wall written into one
> is indistinguishable, from the inside, from a wall in the world.**

Browser access is an admin capability. `NL_BROWSER_DRIVER=1` extends it to sandboxed accounts —
worth a deliberate decision, since the browser inherits this machine's network position and your
profile's logins.

## Three models, one turn — the model trio

A turn is not one kind of work. It streams a reply and calls tools; it decides what *done* means; it
writes itself a one-line instruction for the next step, over and over. Those want different models, so
every LLM call the engine makes is labelled and routed to one of three **roles**:

- **coding** — the agentic step: the reply that streams onto your screen and every tool call inside it
  (`chat`).
- **thinking** — planning and transcript housekeeping: the task breakdown and the acceptance bar
  (`plan`), the post-hoc critique (`reflect`), compaction and the rolling summary (`compact`, `ctxsum`),
  plus `summary` and the scheduled-run `lesson`.
- **prompting** — the short, frequent calls that write the *next instruction* rather than answer
  anything: the auto-loop drive step (`loop`), web-search query rewrites (`searchq`), stuck recovery
  (`stuck`).

**One model for everything is the default and is fully supported.** A role counts as set only when it
has both a model id and a base URL; anything else is blank, and a blank role falls back to coding
(`ModelTrio.pick` in `src/worker/chat/engine.zig`). Leave thinking and prompting empty and the engine
behaves exactly as it did before roles existed. The routing is guarded by a source audit
(`src/worker/chat/trio_routing_test.zig`) that fails `zig build test` if a label ever reaches the wrong role.

Set it in **Settings → Models** (web), **Settings** (desktop), or **Admin → Default model** to publish a
trio to everyone who hasn't chosen their own — per role, so an account that picked only a coding model
still picks up the host's thinking and prompting. For `veil chat` it's environment: `NL_LLM_*` for
coding, `NL_LLM_THINK_*` and `NL_LLM_PROMPT_*` for the other two.

The one thing worth knowing before you choose: **thinking is not uniformly the expensive-model role.**
Measured over real request bodies, `plan` averages about **1 KB** per call and carries all of the
judgment, while `compact` and `ctxsum` are **tens of KB** per turn and are mechanical compression. Both
run on the thinking model, so that single setting pays for a rare high-stakes call and a bulky low-stakes
one at the same time. Prompting is the easy call — small outputs, no judgment, high volume — so it is
the one to make cheap.

Full routing table, the per-call measurements behind that advice, the cost split, and the limitations are
on the docs page: **[the model trio](https://gary23w.github.io/nl-veil/#doc=guide/models)**.

## Scheduled tasks

A scheduled task runs **strictly through chat**: when it comes due, the server mints a fresh
conversation named `scheduled_*` and fires **one ordinary chat turn** at it — so a run persists, streams
its events, shows up in the conversation list, and can be continued by hand afterwards. Manage them with
`veil sched` (admin-gated):

Because every run gets a *new* conversation, a run that was cut short used to leave nothing the next one
could read, and a task that kept hitting the spend ceiling restarted from zero every time. Since
`v1.0.1-beta-6` the engine banks what a cut run established as a **resume anchor** against the task
itself rather than against the transcript, so the next run reads it back and picks up from the step it
names. A run that finishes cleanly clears its own anchor, so this is invisible until something is
actually left unfinished.

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
- **AFK: run until you stop it.** A second tier for leaving the machine. It never asks whether the goal
  is complete (a session you opted into running indefinitely has no end state to ask about), the
  **prompting model writes each re-drive** from what the transcript shows was just built rather than
  reposting a canned sentence, it stays anchored to your original goal instead of to the loop's own
  re-arm text, and it re-grounds itself if a drive step comes back empty twice running. A transient
  provider error no longer ends a run you were promised only you could end, and the steering column
  stays reachable for the whole turn. The ordinary auto-loop tier is unchanged — its stop conditions
  *are* the tier.
- **You see everything.** Live per-round fitness, the files each mind is writing, the tool calls, the
  shared-memory writes — swarm work is transparent, not a spinner.
- **Sub-chats.** Branch a side thread off any conversation (up to five, one level deep) as tabs
  across the top. The family shares one workspace, so a side question doesn't lose the build.
- **Attach an image.** Drop a screenshot or a picture into a message and it is turned into text and
  searchable regions server-side — so the model reads what's in it whether or not it has vision.
- **Manage the built-in model from the window.** A panel shows the weights, a download button, a live
  progress bar, and one click to serve it.
- **It sits in the tray — and closing the window doesn't kill the server.** A system-tray icon and
  native toasts on Windows; it lights up the moment the server has something to show. The desk and the
  server are *one process*, so the titlebar **X hides the window** and leaves everything running — the
  turn in flight, the chat workers, the web UI on `:8787`. Only **File → Quit** or **tray → Quit** ends
  the process. While hidden the loop skips input, layout and drawing entirely and idles at 5 Hz, so a
  parked desk costs nothing. *(Windows only, and only when a live tray icon actually exists to bring the
  window back — Linux and macOS keep the old quit-on-close behaviour rather than hiding a window behind
  an icon that isn't there.)*

The desktop is compiled **into** `veil`, so the released binary is the whole app — double-click and
you're in, server and window together. Same from source:

```sh
zig build run                 # server + desktop, exactly like the release binary
zig build -Dapp=false         # server-only build: no GUI compiled in, no raylib/GL to link
```

`-Dapp=false` is what headless hosts and CI boxes want — the GUI is left out of the compilation
entirely rather than merely unused. To keep the GUI compiled in but not opened for a given run, pass
`--server-only` at runtime. (There is a `zig build desk` step that produces a standalone `veil-desk`
binary; it is a **development** convenience, not something the release ships or the server spawns.)

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
- **Lessons are graded on whether they helped.** At the moment a failure resolves into a verified fix,
  the lesson that was recalled *for that failure* is reinforced — so one that keeps preceding fixes
  surfaces first and one that never does simply fades. It runs before the fresh mint, crediting prior
  knowledge rather than the fix just written, and it is engine-driven, so a mind cannot inflate its own.
- **Recurring successes become candidate procedure.** The engine counts repeated successful tool
  *sequences* per mind — zero extra model calls, folded from records it already keeps — and proposes the
  frequent ones into a quarantine. Nothing auto-registers, auto-runs, or reaches a prompt; promotion is
  a reviewed step like every other proposal.
- **A round that breaks one check while fixing another is visible.** The score is an aggregate, so that
  round used to read as "no change" to every loop watching it. The best-known-good build's failure set
  is now the champion and each later round the challenger, so a new break is reported even when the
  aggregate is flat or rising.
- **Self-edits are verified after the write, not just before it.** Every gate around `patch_system` ran
  *before* the edit landed, so a change that left the source un-parseable stood until the next human
  build. A post-write `zig ast-check` (or the shared syntax gate for other languages) now reverts a bad
  write in place from a pre-image and reports it blocked. Authored tools are compiled the same way
  before they can enter the registry, instead of failing at their first call many rounds later.

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
graded by the engine's own smoke gate and judge.

**The MCP relationship runs the other way today.** veil is an MCP *client*: `mcp_discover` reads the
server configs already on your machine (Claude Desktop, Cursor, VS Code) and probes for local AI
runtimes, and `mcp_call` runs their tools inside a veil turn — config scanning is read-only and never
returns env values, which is where secrets live. Exposing the hive *as* an MCP server, so another
client lists `cast` among its tools, is **planned and not yet built**: there is no `veil mcp` command,
so drive it as a shell command for now.

## How it works

Four pieces, each published on its own, that snap together:

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
  │                                                              │
  │  the-veil-12b            the model, served in-process        │
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
built for you on first run (needs [Rust](https://rustup.rs)); reused after that. Its semantic cortex
is published separately as
**[gary-neuron-emergent](https://huggingface.co/gary23w/gary-neuron-emergent)**.

**It resolves paraphrases.** Recall returning nothing reads to a model as an authoritative *no* and
overrides what is sitting in its own context, so an empty spreading-activation pass no longer ends the
lookup: it falls through to a semantic pass with a topic gate, which can match a question sharing **no
words** with the stored fact. Released bundles build `neuron` with that tier compiled in. Measured
through the chat stack on isolated conversations with identical seeds and phrasing, grounded answers
went **0/3 → 2/3 with one partial** — turn-start recall now injects bridges like *"machine that routes
customer orders" → "the dispatch gateway listens on port 7141"* that a lexical lookup never surfaced.

**[nl-rag](https://github.com/gary23w/nl-rag)** — the knowledge. A curated repository of canonical
documentation (languages, web, databases, security, ops…) pulled and normalized into clean,
frontmattered markdown *packs*, each with a `pack.facts` file. The veil's compiled-in source atlas
points scouts at these packs first, so a small model reads pre-cleaned markdown instead of fighting
HTML — and you can bulk-load a pack straight into hive memory:

```sh
neuron import packs/rust/pack.facts --scope knowledge     # from a cloned nl-rag
```

**[the-veil-12b](https://huggingface.co/gary23w/the-veil-12b)** — the model. Published as GGUF and
served by the server itself, so the fourth piece needs no runtime of its own: `veil model pull` and
the app is self-contained. See [the built-in model](#the-built-in-model--nothing-to-install). Any
other OpenAI-compatible endpoint still works exactly as before — this is the floor, not a lock-in.

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
- **Built-in knowledge base (local corpus mirror).** Point `NL_RAG_DIR` at a clone of
  [nl-rag](https://github.com/gary23w/nl-rag) — or run `veil rag sync --from <clone>` to copy a tier
  into the app's data dir (`veil rag status` shows what's active) — and every pack fetch serves from
  disk: engine prefetch, scout page reads, deep crawls, all offline-capable. The corpus manifest also
  EXTENDS the compiled source atlas at runtime (thousands of extra curated domains become routable),
  with machine-grown packs excluded by default. A clone dropped at `vendor/nl-rag` before build works
  too — the app carries its knowledge with it.

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
| `bootstrap` | `false` disables the engine-run dependency installs of the deliverable's own manifests (npm/pip/cargo/go) |
| `lineage` | a stable id (`veil cast … --lineage my-proj`) that persists the swarm's neuron-db across re-casts, so knowledge, playbook, skills, and learned trust **compound** run over run instead of resetting — a cast that gets better over time |
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
zig build && ./zig-out/bin/veil
```

It binds **every interface** unless you say otherwise, and prints the URLs it is reachable at (see
[step 3](#3-find-the-url)). The admin password for a first run is in `data/admin-password.txt` — the
full first-login sequence is [step 4](#4-log-in-as-the-admin).

### The shared provider key

A default model nobody can afford to call is not a default. **Admin → provider key** stores one
instance-wide key (`POST /api/v1/admin/keys`), sealed in the same vault as everyone else's under a
reserved uid that no account can hold (`SERVER_KEY_UID = 0`, `src/worker/chat/service.zig:30`).

It is the **last** resort in the resolution ladder — an explicitly-supplied key wins, then the user's
own vaulted key, then this one — so an account that brings its own billing is never silently switched
onto yours (`src/worker/chat/service.zig`, `resolveRole`).

**The trade is deliberate and worth stating: once this is set, every user's turns spend the admin's
credit.** That is exactly what a LAN or family install wants — nobody should have to hold an API key
to use the thing — and exactly what a wider deployment has to think about first. Without it, each new
account must configure its own key in Settings before it can chat at all.

### Everyone else is sandboxed

**Set the default model in the Admin tab.** Pick it from the same catalog the Settings tab uses; it
applies immediately, with no restart, to everyone who has not chosen their own. The API key is never
part of it. Without a default, a brand-new account has to configure a model before it can chat at all.

The web app is multi-user, and **a normal account is not trusted with the host**. Its turns run a
restricted tool surface: the conversation's own workspace, research, and the *entire* hive-memory
surface — but no code execution, no host commands, no engine self-modification, no tool authoring, no
browser or MCP drive, and no casting swarms or scheduling runs (both execute outside the sandbox).
The admin account keeps the full surface. Files were always confined to the conversation's workdir;
what changed is that the dangerous verbs are now refused inside a turn, not just on the tool endpoint.

| variable | what it does |
|---|---|
| `NL_BIND` | the listen address. **Unset = every interface**, which is the default and is what makes the phone-in-the-next-room case work. `127.0.0.1` (or `localhost`) pins it to this machine |
| `NL_PORT` | the port (default 8787). Resolved once and shared by the server bind and the CLI client |
| `NL_ADMIN_EMAIL` / `NL_ADMIN_PASSWORD` | the admin account. Defaults to `admin@neuron-loops.local` with a password generated on first run and written to `data/admin-password.txt`; set `NL_ADMIN_PASSWORD` to pin your own and no file is written |
| `NL_MAX_TURNS` | how many chat turns run at once, server-wide (default 64, ceiling 256). Size it to the rate limit of the provider key everyone shares |
| `NL_MAX_TURNS_PER_USER` | how many of those one account may hold (default: an eighth of capacity). This is what stops one busy user starving everyone else |
| `NL_TURN_TOKEN_CEILING` | input tokens one turn **segment** may spend before the engine compacts its working context and continues (default 400000; `0` disables the ceiling). A runaway backstop, not a budget — a thorough research turn lands well under it |
| `NL_TURN_CONTINUE_MAX` | how many times one turn may compact and keep going (default 3). **`0` restores beta-5's behaviour exactly**: the turn settles at the ceiling and waits for you |
| `NL_TURN_CONTINUE_HARD_MAX` | the ceiling on the *earned* allowance (default 10). A segment that wrote a file or made a call it had not made before buys one more pass, up to this; a segment that only re-read its own context buys nothing, so a spinning turn still settles at `NL_TURN_CONTINUE_MAX` |
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
    config/lan.zig         which addresses this machine is reachable at (the startup banner's URLs)
    config/server_config.zig  admin-owned runtime settings → data/server-config.json
  worker/                  the hive and the server-side brain:
    chat/{engine,service,tools,context,plan,sync,toolperf,paths}.zig  the chat brain — the agentic
                                                   turn loop, its REST handlers, tools, context
                                                   window, plan board, client file-sync, tool
                                                   timings, and conversation paths
    sched.zig              scheduled tasks (each run is a server chat conversation)
    continuity.zig         resume anchors — what a cut unit of work established, banked in
                                                   neuron-db so the next run continues it
    control/{supervisor,writer,fanout}.zig  swarm processes, the control bus, event streaming
    deploy/service.zig     the cast/deploy door + swarm files, bundle, archive, lifecycle
    neuron/client.zig      the neuron-db memory bridge (fail-open)
    builtin.zig  builtin_endpoint.zig  llamaeng.zig  llamashim.c  modelpull.zig  the BUILT-IN model:
                                                   the-veil-12b served by the server itself from a
                                                   downloaded GGUF (-Dbuiltin, default true) — store,
                                                   loopback engine endpoint, embedded inference, and
                                                   the verified weights downloader
    gemma4.zig             the Gemma-4 wire format, rendered here instead of by the local runtime
    browser/               the browser driver: its own profile (launch, cdp) or YOUR Chrome/Edge
                           through the extension (ext, ext_api), behind one session model + the
                           per-machine local-host daemon that keeps a session alive across calls
    mcp/{client,discovery}.zig  find and call the MCP servers already installed on this machine
    run.zig  agi.zig  oscillation.zig  rsi.zig  vcs.zig  tools.zig  writer.zig …  the moment loop,
                                                   the Veil, the self-improvement faculties, the
                                                   micro-VCS for concurrent minds
    locs/atlas.zig         the source atlas — points scouts at nl-rag packs
desk/                      veil-desk, the native desktop dashboard — compiled INTO `veil` as the
                           "desk" module (-Dapp, default true), not a separate shipped binary
docs/                      the docs site: architecture map + annotated source (static, home-built
                           md parser, the desk's own palette from desk/src/theme.zig)
extension/                 the Chrome/Edge extension — a thin CDP relay so the veil can drive the
                           browser you are already signed into (load unpacked; nothing to build)
examples/embedded/         the device-operator worked example
harness/TESTING.md         the house test rules — read before adding a test
web/public/                the control-plane UI — index.html, app.js, styles.css, models.json,
                           embedded into the binary at build time (no bundler, no build step)
models.yaml                the ONE model catalog → generated into web/public/models.json
bin/neuron[.exe]           the neuron-db memory engine (bundled / built on first run)
```

Build knobs worth knowing: `-Dapp=false` (no desktop GUI), `-Dbuiltin=false` (no embedded inference),
`-Dvulkan=false` (CPU-only built-in engine, ~50 MB smaller binary). Each one skips fetching its
dependency entirely rather than compiling it unused.

## Release

**Current: [`v1.0.1-beta-6`](https://github.com/gary23w/nl-veil/releases/tag/v1.0.1-beta-6)** — the
sixth beta, about **continuity**. beta-5's spend ceiling stopped a runaway turn but ended it outright,
throwing away everything it had gathered, so the next turn started over and usually hit the same wall
the same way. Now a turn that outgrows its budget distils what the stretch established (*established /
on disk / ruled out / next*), drops the bloated context, and **keeps going on its own** — the allowance
is earned by segments that actually wrote a file or made a new call. The same record is banked durably
in neuron-db as a **resume anchor**, so a scheduled task, which gets a brand-new conversation every run,
resumes yesterday's work instead of restarting it. That whole feature was silently dead on hosted
reasoning models, which spent their entire budget on hidden reasoning and returned nothing; the client
now learns the model and raises the floor by itself. In the desktop, selecting a conversation someone
else is driving refreshes it instead of showing a frozen snapshot.
[Full notes](docs/release/RELEASE-v1.0.1-beta-6.md) ·
[beta-5](docs/release/RELEASE-v1.0.1-beta-5.md) — trusting what the model did ·
[beta-4](docs/release/RELEASE-v1.0.1-beta-4.md) — the governed prompt workspace.

Builds ship on the [Releases page](https://github.com/gary23w/nl-veil/releases), one per
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
`veil doctor` prints server + token health; `veil doctor --runtime` adds what the app has actually
been doing — learned tool behavior, schedule fail-streaks, per-model token and latency usage — and
reads the on-disk ledgers directly, so it works with the server down.

**Related projects:** [neuron-db](https://github.com/gary23w/neuron-db) (the memory engine) ·
[nl-rag](https://github.com/gary23w/nl-rag) (the knowledge packs) ·
[the-veil-12b](https://huggingface.co/gary23w/the-veil-12b) (the built-in model) ·
[gary-neuron-emergent](https://huggingface.co/gary23w/gary-neuron-emergent) (neuron-db's semantic
cortex).

## License

[MIT](LICENSE). Use it, fork it, build on it.
