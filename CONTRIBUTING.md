# Contributing to the veil

Thanks for your interest — contributions are welcome.

1. You need **Zig 0.16+** ([download](https://ziglang.org/download/)). Run `veil doctor` once the
   binary exists for a readiness table (server + token health).
2. Build: `zig build` — the binary lands in `zig-out/bin/veil`. The `neuron` memory engine ships
   prebuilt in `bin/` (or build it from the sibling neuron-db repo — needs a **C compiler** for
   SQLite and the **Rust toolchain** via [rustup](https://rustup.rs)).
3. Get a model endpoint (the easiest is [Ollama](https://ollama.com): `ollama pull gpt-oss:20b`, the
   default — or `llama3.1:8b` on very small devices).
4. `veil` runs the server; `veil cast "say hello" --minutes 1 --follow` confirms the loop runs end
   to end (the CLI auto-starts the server if it isn't already up).

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

Open an issue with what you ran (a `veil` command or `swarm.json`), what you expected, and what
happened — a snippet of the run's `events.jsonl` helps a lot.
