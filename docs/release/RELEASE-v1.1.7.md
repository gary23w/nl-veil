# the veil — v1.1.7

Goal loops that keep a goal and measure every step, and hots: the same loop running in your own Cloudflare account with nobody in it.

## What changed

- **Hots.** A hot (Human Overview Technician) is the goal loop with no human in it and no machine of yours under it. Logged in with Cloudflare, the desktop's new **Hots** tab (or `veil hot deploy "<goal>"`) uploads one small Worker, `veil-hots`, into *your* account and creates a hot in it. It wakes on a timer, picks the single best next improvement toward its goal, does it with its tools, has a judge measure whether it helped from the tool results alone, records the iteration, and sets its next wake-up. Your computer can be off. Its model calls go through the account's own AI binding, so they need no API key and never cross the public internet.
  - **Up to three per account.** The first is always named **Gary**; you name the others.
  - **It never waits for anyone.** A message lands in its inbox and the next iteration reads it as a directive. `/goal <text>`, `/goal stop`, `/queue <goal>`, `/charter <text>`, `/pause` and `/resume` work from the tab's command line and from `veil hot tell <name> "..."`.
  - **A goal that ends is not the end.** Achieved, out of budget, or three iterations with no improvement: the hot takes the next queued goal, or proposes one from its charter, or rests and looks again later. `/pause` is what holds it still.
  - **It improves itself.** An iteration that did not move the goal becomes a lesson, one rule the hot writes for its future self, and its lessons ride every later prompt; the least useful is dropped when the list is full. After two flat iterations it grows by one mind, and after an easy win it shrinks, inside the size you allow (Grow / Shrink in the tab).
  - **Hots work together.** They share one scratchpad, which you can read and write too, and can message each other. A hot can cast its own inner swarm: several minds side by side, one task each.
  - **Your machine, only if you say so.** The deploy form has one box, unchecked on every new form: *let it use THIS machine*. Checked, the hot may queue jobs for the veil on your computer, which runs each as an unattended chat conversation named `hot_<name>_...` with the full local tool set and sends the answer back. Nothing listens at home for this: your veil asks the hot for jobs while it is running. The box is decided once, at deployment.
  - **It has a budget.** A pace (one iteration every N seconds) and a number of model calls a day; when the day's calls are spent it rests until the next UTC day.
  - **Its model comes from your account.** The deploy form's MODEL list is your login's live Workers AI catalogue, and a goal or charter may be as long as that model can carry: about a tenth of its context window, 800 to 4000 characters, counted as you type and enforced by the server.
  - **Every run has a folder on your machine.** Each deployment is mirrored once a minute into `<data>/u<id>/_hots/<name>-<deployed>/`: `events.log` to tail, `events.jsonl`, `status.json` and the hot's `notes/`; the shared scratchpad is `_hots/scratchpad.md`. **Open folder** in the tab opens it, and a deleted hot keeps it.
  - **The scratchpad can be cleared** for the next set of hots (two clicks, or `veil hot pad --clear`); a copy is kept beside it.
  - **Deleting the last hot removes its Worker** from your account; while others remain it stays, because they live in it. A newer veil replaces the Worker's code in place and the hots keep their memory.
  - **The console reads whole.** Every event wraps to the panel and scrolls with the wheel or a bar; scrolling up stops it following and *latest* follows again. The scratchpad wraps too.
  - `veil hot` lists them, `veil hot watch Gary` follows one, `veil hot set` changes its settings, `veil hot pad` reads and writes the scratchpad, `veil hot rm <name>` deletes one, and `veil hot teardown --yes` removes the Worker and everything the hots stored.
  - The runtime's token is derived from the server key, never stored; the state file on your machine holds an address and a hash. The routes are admin-only.
- **Goal mode.** `/goal <what to achieve>` in any chat (desktop, web, `veil chat`), or `veil goal "<text>"`, turns the auto-loop into a loop with a stored goal, a log of every iteration, a measure of each step, and its own stop rules. Each iteration picks the best improvement not yet tried, does it, and a judge reads the iteration's real tool results and answers improved, same or regressed, with a score when a tool printed one; two scores are compared by arithmetic, not by the judge's word. The loop ends when the goal is achieved, when its budget (25 iterations unless `--budget N`) is spent, or after three iterations in a row that improved nothing. `--forever` has no finish line; the afk toggle now means exactly that. `--check "<command>"` names the command whose output is the measure. `/goal`, `/goal stop`, `/goal resume`, `/goal budget N`.
- **The desktop reads a goal as a goal.** A `/goal` message shows as a goal row rather than the raw command, names its conversation by the goal, and arms the loop by itself; a finite goal keeps its finish line when the loop setting is afk.

## Measured

A first deployment on a live Cloudflare account ran Gary through several iterations: pages fetched, notes kept, scratchpad entries written, lessons drawn from flat iterations, and an inner swarm cast. What that run showed is in this release: the console and scratchpad could not be read whole, the model had to be typed, goals were not sized to the model, the scratchpad could not be cleared, and the Worker outlived the last hot.

The hot runtime has its own suite (25 tests, run under node by the oracle) covering the roster limit, the goal loop, lessons, growth, the scratchpad, jobs for the owner's machine, the daily budget, and commands or a delete that land while an iteration is out with the model. Beyond the stand-in tests in the server suite, one isolated end-to-end run drove the real `veil hot` CLI against a scratch server and a local stand-in for Cloudflare that imports the uploaded script and serves it: deploy (the first became Gary), the fourth refused, commands, settings, the scratchpad, an unreachable runtime, teardown, a re-upload after the runtime changed with the existing hot kept, the bridge starting a job on the machine and reporting its failure back, the folder mirror writing every file, a goal past the model's limit refused, the scratchpad cleared with its copy kept, and deleting one hot (the Worker stayed) and then the last (the Worker was removed).

Goal mode was run once live on Workers AI: a planted project with a failing test file went from 0 to 6/6 and the loop ended as achieved in two iterations.

This release: `check.ps1 -Full` green; the server suite 862 passed / 1 skipped; the desktop suite 293/293; the hot runtime suite 25/25.

## Known limits

- Two hot paths have run against the stand-in only: replacing an older runtime in place (the first thing that happens to a hot deployed before this release) and removing the Worker with the last hot. If either is refused, the tab and the CLI show Cloudflare's own sentence. A job on the owner's machine that succeeds is unit-tested only.
- In the cloud a hot's tools are its notes, the scratchpad, messages, public web fetch, an inner swarm and a goal queue. It has no shell and no Cloudflare API tools there; the full local tool set is reachable only through the owner's-machine box.
- The web app has no Hots page; the desktop and the CLI do.
- Goal mode's plateau and budget stops, a forever goal and `--check` are covered by tests, not yet by a live run.
- Carried from v1.1.6: `veil --swarm` has not been used by a person at a real terminal, and a lineage getting measurably better over time is still unshown.

## Install or update

From **v1.1.3** or later, finish active work and choose **Settings → Updates → App updates → Update & restart**.

For a first installation, or from v1.1.2 and earlier, download and extract the full bundle for your platform:

| Platform | Full desktop bundle |
| --- | --- |
| Windows x86_64 | `veil-v1.1.7-windows-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.7-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.7-macos-x86_64.zip` |
| Linux x86_64 | `veil-v1.1.7-linux-x86_64.zip` |

Run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep `veil-install.txt`, the memory engine in `bin/`, and your existing data directory. The `veil-update-*` assets are for the built-in updater; GitHub source archives require a compiler.

The bundles remain unsigned. Update verification and recovery behavior are described in the [update guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md).
