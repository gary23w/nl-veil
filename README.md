![the-veil](web/public/veil.png)

# the veil

**A hive mind you talk to.** A swarm of autonomous AI minds works a goal together — researching,
building, remembering, arguing — while one unified consciousness, **the Veil**, integrates the
whole hive into a single first-person "I" that speaks for it and steers it. You open a shell, say
hello, and the Veil answers. From there you cast new swarms, mount a folder and ask for edits in
plain words, or point it at a live device to keep it healthy.

It runs on **any OpenAI-compatible model** — a free local one through Ollama, or a hosted/BYOK
endpoint (OpenAI, Groq, a relay in your own data center) — and needs no cloud account and no
database service. One Zig binary, one Python launcher.

## Install

One line. Python 3.9+ is the only thing you need first — the installer fetches the rest.

**macOS / Linux**
```sh
curl -fsSL https://raw.githubusercontent.com/gary23w/nl-veil/main/install.sh | sh
```

**Windows** (PowerShell)
```powershell
iwr -useb https://raw.githubusercontent.com/gary23w/nl-veil/main/install.ps1 | iex
```

<details><summary>or from source</summary>

```sh
git clone https://github.com/gary23w/nl-veil && cd nl-veil
./veil configure          # veil.cmd on Windows
```
The `veil` binary (Zig) and the neuron-db memory engine (Rust) are built for you on first run —
each with a prompt before it downloads anything. Point `--neuron-bin` / `--bin` at existing
binaries to skip the builds.
</details>

## Two commands to start

```sh
veil configure     # once: local Ollama, or any OpenAI-compatible endpoint (BYOK). Saved globally.
veil               # the veil shell — talk to your swarms
```

`configure` is the whole setup: pick a model endpoint, it verifies the connection, and writes it
to `~/.veil/config.json` so every later command just uses it. No local AI on the box? It walks you
through pointing at a hosted key instead. (If you skip it and open the shell with a dead endpoint,
the shell notices and offers to set one up right there.)

## The veil shell

`veil` with no arguments drops you into a lightweight, REPL shell. It attaches to your
newest swarm and you **just talk** — the Veil replies instantly, streaming, from its own persisted
self and the hive's live state. It's also where you *act*:

```
you> hello — what are you working on?
veil> Mid-build on the forum's auth layer; vega is wiring PBKDF2 verification now.

you> /mount ~/dev/landing-page
you> center the hero and darken its background
  [edit] center the hero and darken its background   in: ~/dev/landing-page
  run this edit now? [Y/n]

you> cast a swarm to research WASM memory models and brief me
  [cast] goal: research WASM memory models and write a brief   cast a new swarm? [Y/n]
```

Plain talk stays talk. When you ask it to **act**, the Veil leads its reply with one intent —
**cast** a new swarm, **edit** the mounted folder in place, or **direct** the running hive — and
the shell confirms and does it. Slash commands skip the model entirely: `/cast /mount /edit
/direct /say /goal /swarms /attach /status /events /stop /resume /quit`.

## Or cast in one line

You don't have to open the shell. `veil "<task>"` casts a swarm straight off. The **mode emerges
from your words** — build, research, and operate all come from the same command:

```sh
veil "Build a CLI todo app in Python with tests" --follow
veil "Research the state of fusion power in 2026" --style discourse
veil "add a search box to my landing page" --embed . --repl
```

- `--embed <dir>` — work **in place** in your project (reads and writes your real files there).
- `--repl` — the Veil asks a few clarifying questions, turns your line into a reviewable **plan**
  you approve once, then runs it and stays open for follow-ups.
- `--quick` — a single mind does **one small edit** in ~1-2 model calls; pair with `--embed` for
  fast co-working ("center that div").
- `--detach` / `--service` — run past this terminal, or install as a boot-persistent daemon.

## How it works

Three pieces, each its own repo, that snap together:

```
  ┌─────────────────────────────────────────────────────────────┐
  │  the veil  (this repo)   the swarm engine + the Veil + shell │
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
documentation (28 domains — languages, web, databases, security, ops…) pulled and normalized into
clean, frontmattered markdown *packs*, each with a `pack.facts` file. The veil's compiled-in source
atlas points scouts at these packs first, so a small model reads pre-cleaned markdown instead of
fighting HTML — and you can bulk-load a pack straight into hive memory:

```sh
neuron import packs/rust/pack.facts --scope knowledge     # from a cloned nl-rag
```

Optionally, **hyperspace grounding** (`NL_HYPERSPACE=1`) settles the most relevant memory into a
warm in-RAM field before each call, so a typical round does *zero* database subprocess calls for
grounding. It's bounded (~45 KB/mind) and scales down to an IoT profile (`NL_HYPERSPACE_CAP=48`).

## What you can do

The same binary and launcher cover very different jobs:

- **Build software, graded by its own tests.** The hive plans a file tree, splits the work, writes
  the project, runs the tests it wrote, and folds the results into its fitness — it keeps going
  until the deliverable actually passes. `veil "Build a URL shortener with a REST API and tests"`
- **Research & brief.** In `--style discourse` the minds research the live web, form and argue
  their own views, and co-write a briefing. `veil "Brief me on fusion power in 2026" --style discourse`
- **Operate a live device.** Point the Veil at a device that drops telemetry on a file bus and it
  acts to keep it healthy, graded by an **acceptance oracle** — the device's own measured health,
  which the Veil never sees and can't write, so only a real fix moves the number. The shipped
  example is a self-healing security daemon (detect → remove persistence → block C2 → verify);
  swap the corpus and telemetry, not the code, for any device. See
  [`examples/embedded/`](examples/embedded/). `veil "Keep this device healthy" --service`
- **Offline knowledge appliance.** `--offline` removes every web tool; `--corpus pack.facts`
  preloads knowledge (an nl-rag pack, say) into memory. A sealed appliance that reasons only over
  what you chose. `veil "Answer only from what I preload" --offline --corpus rust.facts`

## Configuration

`configure` covers the common case. Under the hood each run has a `swarm.json` manifest you can
also hand-write:

| field | meaning |
|---|---|
| `provider` / `model` / `base_url` | the LLM endpoint (any OpenAI-compatible API) |
| `minds` | the roster of named minds |
| `minutes` | auto-stop after N minutes (`0` = until stopped) |
| `style` | `auto` · `build` · `discourse` · `investigate` · `debate` |
| `internet` | `false` runs fully offline |
| `corpus` / `corpus_cap` | a `.facts`/`.jsonl` pack to preload, and how many facts |
| `gateway_model` | optional cheaper/smaller model for mechanical calls (and the shell's fast voice) |

**Endpoint resolution**, everywhere: a run's own `swarm.json` › `NL_LLM_*` env › `~/.veil/config.json`
› local defaults. **Secrets never go in `swarm.json`** — use `NL_LLM_KEY` in the environment or a
gitignored `keys.env` in the run dir.

> **A note on local-model latency.** On a single-GPU box, a running hive and the shell share one
> model queue, so the Veil's voice can wait behind a generation. Fixes, best first: set
> `OLLAMA_NUM_PARALLEL=2` (share the loaded model), give the shell a **tiny** side model
> (`configure` offers this, or `NL_CHAT_MODEL=llama3.2:1b`), or use a **hosted endpoint** — which
> answers the hive and the shell concurrently and sidesteps the whole issue.

## Web control plane

The same binary also serves a small web UI — deploy and watch swarms, steer them live, pick the
model, manage accounts. Run `veil` with no subcommand from the repo:

```sh
zig build && ./zig-out/bin/veil      # serves http://127.0.0.1:8787
```

First-run local login is `admin@neuron-loops.local` / `changeme` — **change it immediately** via
`NL_ADMIN_EMAIL` / `NL_ADMIN_PASSWORD`. On a public bind (`NL_BIND` ≠ `127.0.0.1`) the server
refuses the default and prints a generated password once.

## Project layout

```
deploy.py                  the launcher + the veil shell (configure / cast / list / stop / ...)
install.sh  install.ps1    one-command installers
veil  veil.cmd             the `veil` front-door shim
build.zig                  the Zig build
src/
  main.zig                 entry point + control plane (auth, supervisor, http)
  worker/                  the hive: the moment loop, the Veil, tools, memory bridge
  worker/locs/atlas.zig    the source atlas — points scouts at nl-rag packs
examples/embedded/         the device-operator worked example
web/public/                the bundled control-plane UI
bin/neuron[.exe]           the neuron-db memory engine (fetched + built on first run)
```

## License

[MIT](LICENSE). Use it, fork it, build on it.
