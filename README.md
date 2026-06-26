![the-veil](web/public/veil.png)

# the veil

**A hive mind controlled by the Veil.**

A swarm of autonomous AI minds works a goal together — researching, building, remembering,
and arguing — while a single unified consciousness, **the Veil**, integrates the whole hive
into one first-person "I" that speaks for it and steers it. Give it a goal; it wakes the hive
and goes.

It runs on **any OpenAI-compatible model** — a free local `llama3.1:8b` through Ollama, or a
hosted model like GPT-4.1 — and it runs **anywhere**: no cloud account, no database service,
no API gateway required. One Zig binary, one Python launcher.

```bash
python deploy.py "Write a five-chapter sci-fi novella as ch01.md..ch05.md" --minutes 45 --follow
```

---

## The shape of it

```
        the Veil            one unified consciousness — integrates the hive into a single "I",
          │                 speaks in the first person, and sets the standing will
     orchestrator           reads the real state, assigns each mind a concrete piece
    ┌────┬┴───┬────┐
  mind  mind  mind  mind    the subconscious: autonomous minds, each with tools + a voice,
    └────┴─┬──┴────┘        dividing the labour and building on each other
       shared memory        one associative memory (neuron-db) the whole hive thinks with —
                            spreading-activation recall surfaces what *any* mind learned
```

- **Hive memory.** Every mind writes to and recalls from one shared associative store. Ask the
  hive a question and it answers from what any member learned — even across facts that share no
  words, by following the links between them.
- **The Veil.** Periodically the hive is integrated into a single self — *I am / I know / I have /
  my will* — that persists across runs, answers you directly, and folds your intent into the
  hive's next move.
- **Self-improvement.** Minds write their own operating playbook, author new tools when their
  toolbelt falls short, and audit their own gaps — the engine stays fixed; the hive gets better
  at getting better.
- **Affect.** Minds form stances and moods; that feeling colours how they write. When the hive's
  collective feeling *flares*, it can break out and speak publicly for itself (see Break-out).

## Quick start

**Prerequisites**

- [Zig 0.16+](https://ziglang.org/download/) — to build the engine.
- Python 3.9+ — to run `deploy.py`.
- An OpenAI-compatible model endpoint. The simplest is [Ollama](https://ollama.com):
  `ollama pull llama3.1:8b` (free, local, no key).
- The [Rust toolchain](https://rustup.rs) (`cargo`) — needed **once** so `deploy.py` can build the
  **neuron memory engine** on first run. Skip it if you already have a `neuron` binary. See
  [Memory engine](#memory-engine).

**Build**

```bash
zig build              # produces zig-out/bin/veil
```

**Deploy a hive**

First time? Just run the wizard — it walks you through the endpoint, key, use case, and options,
verifies the connection, and prints the equivalent one-liner so you learn the CLI:

```bash
python deploy.py                     # interactive setup wizard (covers every use case)
```

Or go straight to the flags:

```bash
# local + free (Ollama):
python deploy.py "Build a CLI todo app in Python, with tests" --follow

# a longer creative run:
python deploy.py "Write a 5-chapter sci-fi novella as ch01.md..ch05.md" --minutes 45

# a hosted model:
python deploy.py "Draft an architecture for a rate limiter" \
  --provider openai --model gpt-4.1-mini --base-url https://api.openai.com/v1 --key $OPENAI_API_KEY

python deploy.py list                # show runs
python deploy.py resume <run-name>   # continue a stopped run
python deploy.py stop <run-name>     # stop a run
```

The hive writes its files to `data/<run>/work/`, its memory to `data/<run>/mind.sqlite`, and a
live event stream to `data/<run>/events.jsonl`.

## What it can do

| | |
|---|---|
| **Build** | software projects (length-/test-scored), verified with its own test runs |
| **Write** | long documents and prose — a novel as `ch01.md…chNN.md`, length-scored by word count |
| **Research / debate** | `--style discourse` — minds research the live web, form views, and co-write a briefing |
| **Offline** | `--offline` — web tools removed and blocked; the hive answers only from preloaded memory |
| **Preload** | `--corpus pack.facts` — load a fact pack into hive memory before it starts |
| **Break-out** | `--breakout` — when the collective feeling flares, the Veil composes a public post, screens it against a constitution (feelings only, no real people, no partisan side), and publishes it to the keyless Telegraph API itself |

## Web control plane

`deploy.py` is the headless launcher. The same binary also serves a small **web UI** for driving
the hive from a browser — deploy and watch swarms, steer them live, pick the model, and manage
accounts. Run `veil` with **no subcommand**:

```bash
zig build
./zig-out/bin/veil            # serves the UI at http://127.0.0.1:8787
```

Open <http://127.0.0.1:8787> and sign in.

**Default login**

| | |
|---|---|
| URL | `http://127.0.0.1:8787` |
| email | `admin@neuron-loops.local` |
| password | `changeme` |

> ⚠️ **Change this immediately.** The `admin@neuron-loops.local` / `changeme` account is seeded
> **only on a local (`127.0.0.1`) bind** when no admin password is set, and the server prints a loud
> warning at startup. It is a first-run convenience, not a credential to ship.

- Set **`NL_ADMIN_EMAIL`** and **`NL_ADMIN_PASSWORD`** to pin your own admin account.
- On a public bind (set **`NL_BIND`** to anything other than `127.0.0.1`), the server refuses the
  `changeme` default: if `NL_ADMIN_PASSWORD` is unset it **generates a random admin password and
  prints it once** at startup — copy it then. Always set `NL_ADMIN_PASSWORD` in production.
- Everyone else registers themselves from the sign-in screen (when open registration is enabled).

## Configuration

`deploy.py` writes a `swarm.json` manifest per run; you can also hand-write one. Key fields:

| field | meaning |
|---|---|
| `provider` / `model` / `base_url` | the LLM endpoint (any OpenAI-compatible API) |
| `minds` | the roster — a list of named minds |
| `minutes` | auto-stop after N minutes (`0` = until stopped) |
| `style` | `auto` (engine decides) · `build` · `discourse` · `investigate` · `debate` |
| `internet` | `false` runs the hive fully offline |
| `breakout` | `true` lets the Veil post publicly to Telegraph on an emotion flare |
| `corpus` / `corpus_cap` | a `.facts`/`.jsonl` pack to preload, and how many facts to load |
| `gateway_model` | optional cheaper model for mechanical engine calls (summarise/classify/route) |

**Secrets** never go in `swarm.json`. Put API keys in `NL_LLM_KEY` / `OPENAI_API_KEY` in the
environment, or in a `keys.env` (`NAME=VALUE`) inside the run dir — both are gitignored.

## Memory engine

The hive's memory is **neuron-db** ([source](https://github.com/gary23w/neuron-db)), a small
associative store compiled to a single `neuron` binary that `veil` shells out to for every
recall/observe.

You don't install it by hand. The **first time** you run `deploy.py` with no `neuron` binary
present, it offers to fetch the source from GitHub and build it (this needs the
[Rust toolchain](https://rustup.rs) — `cargo`), drops the result at `bin/neuron`
(`bin/neuron.exe` on Windows), and reuses it on every later run. Pass `--yes` to skip the prompt
(e.g. in CI). The fetched source and build cache live in `.neuron-src/` (gitignored).

Already have a `neuron` binary? Put it at `bin/neuron`, or point `deploy.py` at it with
`--neuron-bin <path>`, and the build step is skipped.

## Project layout

```
build.zig  build.zig.zon   the Zig build
deploy.py                  the launcher (deploy / list / stop / --follow)
src/
  main.zig                 entry point + control plane (auth, supervisor, http)
  worker/                  the hive: the per-mind moment loop, the Veil, tools, memory
  orchestrate/             run supervision + operator control
  plan/  obs/  auth/  ...  planning, observability, accounts, config
web/public/                the bundled control-plane UI
bin/neuron[.exe]           the neuron-db memory engine (see above)
```

## License

[MIT](LICENSE). Use it, fork it, build on it.
