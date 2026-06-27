# Contributing to the veil

Thanks for your interest — contributions are welcome.

1. You only strictly need **Python 3.9+**. Run `python deploy.py doctor` for a readiness table —
   it shows what's present and what `deploy.py` will auto-install for you.
2. `deploy.py` bootstraps the build toolchain on first run: it downloads a pinned **Zig** into
   `./.zig` if `zig` is missing, and installs the **Rust toolchain** via [rustup](https://rustup.rs)
   if `cargo` is missing (needed once to build the `neuron` memory engine — skip it entirely with an
   existing `neuron` binary via `--neuron-bin <path>`). The one thing it can't auto-install is a **C
   compiler** (neuron compiles SQLite); `doctor` prints the one-liner for your OS.
3. Get a model endpoint (the easiest is [Ollama](https://ollama.com): `ollama pull gpt-oss:20b`, the
   default — or `llama3.1:8b` on very small devices; `deploy.py` will offer to install Ollama and pull
   the model for you too).
4. To build by hand: `zig build` — the binary lands in `zig-out/bin/veil`.
5. `python deploy.py "say hello" --minutes 1 --follow` confirms the loop runs end to end
   (the first run fetches + builds `neuron`; pass `--yes` to take every auto-install default).

## Ground rules

- **Build green.** `zig build` must pass before you open a PR.
- **Keep it dependency-light.** The engine is one Zig binary plus `httpz`; please don't add heavy deps.
- **Comments are sparse on purpose.** Each `.zig` file carries a one-line `//!` summary; keep new
  code self-explanatory rather than heavily commented.
- **No secrets, ever.** Don't commit keys, tokens, or `keys.env`. The hive holds no credentials by
  design — outbound actions are staged for human approval, never executed with embedded creds.
- **The safety floor is the engine's, not the hive's.** The operator STOP, the protected scoreboard,
  and the public-post constitution are engine-owned guardrails; please don't route around them.

## Pull requests

- Keep PRs focused; describe the behaviour change and how you verified it.
- For engine changes, say what you ran and what you observed (a short run log is ideal).
- Be kind in review. We assume good faith.

## Reporting issues

Open an issue with what you ran (`deploy.py` command or `swarm.json`), what you expected, and what
happened — a snippet of the run's `events.jsonl` helps a lot.
