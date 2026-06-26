# Contributing to the veil

Thanks for your interest — contributions are welcome.

## Getting set up

1. Install [Zig 0.16+](https://ziglang.org/download/) and Python 3.9+.
2. Get a model endpoint (the easiest is [Ollama](https://ollama.com): `ollama pull llama3.1:8b`).
3. Install the [Rust toolchain](https://rustup.rs) so `deploy.py` can build the `neuron` memory
   engine on first run (or drop an existing `neuron` binary at `bin/`). See the README.
4. `zig build` — the binary lands in `zig-out/bin/veil`.
5. `python deploy.py "say hello" --minutes 1 --follow` to confirm the loop runs end to end
   (the first run fetches + builds `neuron`; pass `--yes` to skip the prompt).

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
