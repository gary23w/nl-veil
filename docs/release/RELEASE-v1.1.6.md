# the veil — v1.1.6

A swarm you can watch from the terminal and talk to as one voice, and lineages that keep what the task requires.

## What changed

- **`veil --swarm "<goal>"`.** Casts a swarm and opens a terminal view of it. On the right, one panel per mind: its name and role, the tool it is on, its last result, lit up as each new step lands, and under them the files the swarm has touched. On the left, the broker chat: a typed line goes to the swarm's one voice (it answers in first person and hands your instruction to every mind), and the swarm's replies, mind-to-operator messages, goal changes and completion arrive as lines. `/stop`, `/goal <text>`, `/say <text>`, `/quit`; Ctrl-C leaves the swarm running. Nothing is configured: the panels, roles and files come from the event stream. The swarm needs no human: it runs continuous by default (`--once` for a strike), with as many minds as the goal needs (the server counts the goal's distinct parts and declared deliverables, adds a scout for research and a reviewer for tests, within your plan's limit; `--minds N` to choose), and the view leaves when the run ends. `--background` casts the same way and returns at once with the id. The screen redraws only when something changed, so an idle swarm costs nothing.
- **Lineages keep the task, not just the process.** The end-of-run judge now proposes **facts**: requirements a tool output stated (a checker's rule, a function's real signature, a data file's real format), and a kept fact is read whole by every mind of the next cast as a *proven task fact*. A proposal that restates one already live, pending or rejected, or that pastes tool JSON, is dropped before review. This came from measurement: with lessons alone, a lineage stored "read the file first" and never the two house rules its checker printed on every run.
- **Every cast of a lineage is on record.** A finished cast appends its outcome (rounds, the engine's best round score, calls, tokens, proposals added) to the lineage's `history.jsonl`; `GET /api/v1/lineages/<id>` serves it, and the list now carries `facts` and `casts` counts.
- **The desktop knows lineages.** Deploy has a LINEAGE field, with your existing lineages offered as one-click chips so a re-cast picks the same id. **Swarm → Lineages** shows each lineage's memory (facts, lessons, skills, playbook), what awaits review, and its casts over time as small bars (round score, rounds, input tokens) with an older-half to newer-half trend line; *cast again* prefills Deploy, *review N proposals* opens the Memory cards.
- **The CLI is configured when the desktop is.** `veil` now reads the desktop's own settings file: the server host and port it points at, and the chat model it uses become the CLI's, so casts and swarms with no `--model` use the model the desktop chats with. A machine with no desktop connects with `veil --configure` (host, port, token; it asks when given no flags, writes the same file, and proves the connection), which is also how a headless box reaches a remote veil. `NL_PORT` and explicit flags still win.
- **`veil cast --follow` ends when the swarm ends.** It waited for a chat `done` no swarm ever writes, so it ran on for five minutes after every swarm finished.

## Measured

The lineage bench (a planted project whose checker states two house rules the goal does not, six casts per arm on `@cf/deepseek-ai/deepseek-v4-flash-0731`): the lineage arm now holds both house rules as facts, word for word, where the v1.1.5 lineage held generic process advice. Hidden-case scores did not move (fresh casts 0.99, the lineage 0.96, one dip to 0.89 on rounding cases that recovered), because fresh casts already score 97–100% on this task. The claim this release makes is that a lineage keeps the task's rules; whether that makes later casts better needs a harder task to show.

`veil --swarm` was verified end to end on a live two-mind cast: it cast, followed two rounds to 3/3 (100%), rendered 70 frames, left on the swarm's `stopped` and printed the summary. Its model, renderer and line editor are unit-tested at every terminal size from 25×9 to 200×50.

This release: `check.ps1 -Full` green; the server suite 841 passed / 1 skipped; the desktop suite 283/283.

## Known limits

- `veil --swarm` has not yet been used by a person at a real terminal; every check was by tests and a piped run. Operator messages reach the minds at the swarm's next round boundary, so a reply takes a round or two; the chat says so once. The desktop's swarm console still does not show the swarm's replies.
- A lineage getting measurably better over time is still unshown, for the reason above.
- The Cloudflare tool-belt simulation still cannot be scored under containment (`curl: (3) No host part in the URL` on model calls), unexplained.

## Install or update

From **v1.1.3** or later, finish active work and choose **Settings → Updates → App updates → Update & restart**.

For a first installation, or from v1.1.2 and earlier, download and extract the full bundle for your platform:

| Platform | Full desktop bundle |
| --- | --- |
| Windows x86_64 | `veil-v1.1.6-windows-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.6-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.6-macos-x86_64.zip` |
| Linux x86_64 | `veil-v1.1.6-linux-x86_64.zip` |

Run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep `veil-install.txt`, the memory engine in `bin/`, and your existing data directory. The `veil-update-*` assets are for the built-in updater; GitHub source archives require a compiler.

The bundles remain unsigned. Update verification and recovery behavior are described in the [update guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md).
