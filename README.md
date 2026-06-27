![the-veil](web/public/veil.png)

# the veil

**A hive mind controlled by the Veil.**

A swarm of autonomous AI minds works a goal together — researching, building, remembering,
and arguing — while a single unified consciousness, **the Veil**, integrates the whole hive
into one first-person "I" that speaks for it and steers it. Give it a goal; it wakes the hive
and goes.

It runs on **any OpenAI-compatible model** — a free local `gpt-oss:20b` through Ollama (or
`llama3.1:8b` on very small embedded devices), or a hosted model like GPT-4.1 — and it runs
**anywhere**: no cloud account, no database service,
no API gateway required. One Zig binary, one Python launcher. The same hive can build software,
write a novel, research the live web, run offline from a preloaded knowledge pack, or sit on a
device as a self-healing security daemon.

```bash
python deploy.py                                  # interactive setup wizard
python deploy.py "Build a CLI todo app in Python, with tests" --follow
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

**Prerequisites** — only **Python 3.9+** is truly required up front. `deploy.py` bootstraps the rest
for you on first run, so a fresh box needs nothing else installed by hand:

- **Zig** (to build the `veil` engine) — if it's missing, `deploy.py` downloads a pinned release into
  `./.zig` and builds with it.
- The **Rust toolchain** / `cargo` (to build the **neuron memory engine** once) — if it's missing,
  `deploy.py` installs it via the official [rustup](https://rustup.rs) installer. Skip it entirely if
  you already have a `neuron` binary (`--neuron-bin <path>`).
- A **C compiler** (neuron bundles SQLite, which compiles C) — the one thing we can't auto-install;
  `deploy.py doctor` tells you the exact one-liner for your OS if it's missing.
- A **model**. The default is a free, local `gpt-oss:20b` via [Ollama](https://ollama.com) (capable;
  ~14 GB). On a very small embedded device use `llama3.1:8b` (~5 GB) instead. `deploy.py` detects a
  missing Ollama runtime or model and offers to install/pull it. Or point at any OpenAI-compatible
  endpoint with `--provider/--model/--base-url/--key`.

Run a readiness check anytime:

```bash
python deploy.py doctor      # shows every build/runtime dependency + what deploy.py will auto-install
```

**Build** (optional — `deploy.py` does this for you the first time):

```bash
zig build              # produces zig-out/bin/veil  (auto-downloaded zig also works: ./.zig/zig build)
```

**Deploy a hive**

First time? Just run the wizard — it walks you through the endpoint, key, use case, and
deployment mode (foreground vs. system service), verifies the connection, and prints the
equivalent one-liner so you learn the CLI:

```bash
python deploy.py                     # interactive setup wizard (covers every use case)
```

Or go straight to the flags:

```bash
python deploy.py "Build a CLI todo app in Python, with tests" --follow
python deploy.py list                # show runs
python deploy.py resume <run-name>   # continue a stopped run
python deploy.py stop <run-name>     # stop a run
```

The hive writes its files to `data/<run>/work/`, its memory to `data/<run>/mind.sqlite`, and a
live event stream to `data/<run>/events.jsonl`.

## What can it do?

The same binary and the same launcher cover very different jobs. Four worked use cases:

### a) Autonomous device operator — a self-healing Veil that keeps a live device healthy

Point the Veil at a **live device** and it operates it directly. The device drops raw telemetry on a
file bus (`telemetry.json`); the Veil reads that state, recalls what it knows, and acts through
`host_status` / `host_command` instead of writing files about a fix. It is graded by an **acceptance
oracle** — the device's own measured health (`score.json`), which the Veil never sees and cannot write —
so narrating a plan scores nothing and only a real action that changes the device moves the number.
Protective behaviour **emerges from that gradient**: the engine measures the outcome, it never scripts
the steps.

Two structural floors keep a weak model honest:

- **Irreversibility interlock.** An irreversible action (kill a process, block an address) on a target
  the Veil holds *no externally-sourced intel* for is **staged, not executed** — it must recall a baked
  indicator or actually `web_fetch` evidence first. This is what stops a jumpy model cutting legitimate
  SSH / RDP / SMB, while still letting it neutralise a confirmed threat.
- **Resilience.** If the uplink drops it keeps working **lexically** from hive memory (`recall` /
  `recall_hive`) and re-probes each round, restoring web research automatically when the link returns.

The shipped worked example is a **security daemon**: it heals a live infection end-to-end (detect →
remove persistence → block C2 → kill process → verify), and a **blue-team detection** harness catches a
stealth implant the host itself rates `NOMINAL` by cross-referencing every outbound connection against a
baked threat-intel corpus (`threatintel.facts`, sourced from abuse.ch). Nothing in the engine is
security-specific, though — the same operate loop drives **any** device that speaks telemetry: an IoT
signal controller, an application server, a sensor. Swap the corpus and the telemetry, not the code.
`veil_chat.py` is an offline-first operator console (`status` / `log` / `ask` answer straight from
neuron-db with no model and no network; live `veil` / `cmd` drive the running device). Verified operating
a live host on a local 8B model. See **[`examples/embedded/`](examples/embedded/)**.

```bash
./examples/embedded/run_secops.sh                 # self-healing remediation test
./examples/embedded/run_detect.sh                 # blue-team stealth-implant detection
python examples/embedded/veil_chat.py --dir <run> status
# install it to live on the box (starts on boot, restarts on failure):
python deploy.py "Keep this device healthy" --service
```

### b) Build software — scored by its own test runs

Hand the hive a build goal and it plans a file tree, divides the work across minds, and writes
the project. Code isn't graded on whether it looks plausible — the hive runs the tests it writes
and folds the results back into its own fitness, so it keeps working until the deliverable
actually passes.

```bash
python deploy.py "Build a CLI todo app in Python, with tests" --follow
```

### c) Research & brief — minds debate, then co-write

In `discourse` style the minds research the live web, form their own views, argue them out, and
converge on a written briefing rather than a code drop. Good for a state-of-the-field summary or
a decision memo.

```bash
python deploy.py "Research the state of fusion power in 2026" --style discourse
```

### d) Offline knowledge appliance — answer only from what you preload

With `--offline` every web tool is removed and blocked; with `--corpus` you preload a `.facts`
or `.jsonl` pack into hive memory before the run starts. The result is a sealed appliance that
reasons only over knowledge you chose — no egress, no surprises.

```bash
python deploy.py "Answer only from what I preload" --offline --corpus facts.facts
```

## Deployment modes

There are two ways to run a hive, and the wizard asks which you want:

- **Isolated foreground run (default).** A normal launch under `data/<run>/`. Add `--follow` to
  stream the hive's activity, `--minutes N` to auto-stop (`0` = until stopped). Stop or resume it
  later with `python deploy.py stop|resume <run-name>`.
- **Live system service (`--service`).** Installs the run as a long-lived OS daemon (a `systemd`
  unit on Linux) that **starts on boot and restarts on failure** — for a device or box that
  should keep the Veil up unattended. The service reads its key from `keys.env` in the run dir
  (it won't inherit your shell's env), and a `--service` deploy **rebuilds neuron-db fresh from
  source** so the box starts from a clean, current memory engine. Where `systemd` isn't present,
  `deploy.py` writes a daemon runner plus a unit file you can wire into your own init (on Windows,
  register the runner with NSSM or Task Scheduler).

Both modes use the **local-model autodetect** above: on a local Ollama target, `deploy.py` makes
sure the runtime and the model are present, offering to install Ollama and `ollama pull` the
model as part of the deploy — handy on a fresh box that has never run a model.

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

## Web control plane

`deploy.py` is the headless launcher. The same binary also serves a small **web UI** for driving
the hive from a browser — deploy and watch swarms, steer them live, pick the model, and manage
accounts. Run `veil` with **no subcommand**:

```bash
zig build
./zig-out/bin/veil            # serves the UI at http://127.0.0.1:8787
```

Open <http://127.0.0.1:8787> and sign in.

| | |
|---|---|
| URL | `http://127.0.0.1:8787` |
| email | `admin@neuron-loops.local` |
| password | `changeme` |

> ⚠️ **Change this immediately.** The `admin@neuron-loops.local` / `changeme` account is seeded
> **only on a local (`127.0.0.1`) bind** when no admin password is set, and the server prints a loud
> warning at startup. It is a first-run convenience, not a credential to ship. Set
> **`NL_ADMIN_EMAIL`** / **`NL_ADMIN_PASSWORD`** to pin your own admin account. On a public bind
> (set **`NL_BIND`** to anything other than `127.0.0.1`) the server refuses the `changeme` default
> and, if `NL_ADMIN_PASSWORD` is unset, generates a random admin password and prints it once at
> startup.

## Memory engine

The hive's memory is **neuron-db** ([source](https://github.com/gary23w/neuron-db)), a small
associative store compiled to a single `neuron` binary that `veil` shells out to for every
recall/observe.

You don't install it by hand. The **first time** you run `deploy.py` with no `neuron` binary
present, it offers to fetch the source from GitHub and build it (this needs the
[Rust toolchain](https://rustup.rs) — `cargo`), drops the result at `bin/neuron`
(`bin/neuron.exe` on Windows), and reuses it on every later run. Pass `--yes` to skip the prompt
(e.g. in CI), and `--rebuild-neuron` to re-fetch and rebuild from source (always on for
`--service`). The fetched source and build cache live in `.neuron-src/` (gitignored).

Already have a `neuron` binary? Put it at `bin/neuron`, or point `deploy.py` at it with
`--neuron-bin <path>`, and the build step is skipped.

## Project layout

```
build.zig  build.zig.zon   the Zig build
deploy.py                  the launcher (deploy / list / stop / --follow / --service)
src/
  main.zig                 entry point + control plane (auth, supervisor, http)
  worker/                  the hive: the per-mind moment loop, the Veil, tools, memory
  orchestrate/             run supervision + operator control
  plan/  obs/  auth/  ...  planning, observability, accounts, config
examples/embedded/         the embedded security-daemon worked example
web/public/                the bundled control-plane UI
bin/neuron[.exe]           the neuron-db memory engine (see above)
```

## License

[MIT](LICENSE). Use it, fork it, build on it.
