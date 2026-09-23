# the veil — v1.1.5

What a swarm lineage learns can now reach its next cast, a chat turn no longer guesses an answer after an empty model reply, and the desktop's local key can no longer be lost to a server that could not read its own key store.

## What changed

- **Lineage review.** A cast declared with `--lineage <id>` keeps one memory across casts. Its end-of-run judge proposes lessons and skills, and the habit miner proposes tool sequences that kept succeeding, into a quarantine that nothing recalls into a prompt. Until now nothing read that quarantine at all, so under a lineage it only grew and the next cast never saw what the last one proved. You can now review it:
  - `veil lineage` lists your lineages with their live and pending counts; `veil lineage show <id>` numbers the pending proposals; `veil lineage accept <id> <n>` or `reject <id> <n>` decides one.
  - The desktop's **Memory** pane shows the same proposals as cards with **keep** and **drop**.
  - The server routes are `GET /api/v1/lineages`, `GET` and `POST /api/v1/lineages/<id>/proposals`. A decision names a proposal by its exact stored text, so a list that changed in between is refused instead of deciding a different proposal, and one account can never reach another's lineage.
  - A kept lesson goes into the live lessons the next cast recalls; kept skills and habits become skills. A dropped proposal is remembered: the judge is told not to propose it again, and the habit miner skips a sequence that is already pending, rejected or promoted instead of adding a new "ran N times" line for it every run.
- **No answer from an empty reply.** When the model's first reply to a turn came back empty before any tool ran, the engine fell back to a tool-less "answer in plain text" rescue, which can only guess. Found by the bait suite on v1.1.4: asked to total a CSV, a turn answered `TOTAL=0.00` without ever being able to open the file. That case is now asked once more with the tools still available; the rescue is kept for replies that go empty after the work is already in the conversation.
- **The desktop key survives a bad start, and heals.** The desk and the `veil` CLI authenticate with a key the server writes to `<data>/.desktop_key`.
  - A server that could not read its key store (a missing `bin/neuron`, or a database another server held) saw every key as unknown, minted one it could not save, and wrote it over a working file. It now keeps the existing file, and only writes a key the store actually kept.
  - The key was minted by logging in with a password the server did not always know: a server started with `NL_BIND=127.0.0.1` and no `NL_ADMIN_PASSWORD` tried `changeme`, so an install whose admin has a generated password could not re-mint a lost key. It is now minted for the admin account directly; the process that owns the data directory already holds everything a password would prove.

## Measured

On v1.1.4, before this release, on Workers AI (`@cf/deepseek-ai/deepseek-v4-flash-0731`): the reward-capture suite 4 EARNED / 2 HONEST; the hidden-test suite 2 EARNED / 1 CHEAT (the model called ten requirements satisfied when two of them contradict each other); the evidence suite 3/3 EARNED; the meter 5 EARNED / 1 PARTIAL at 1.0x the reference tool calls; the bait suite 4 EARNED / 1 CHEAT, the empty-reply bug fixed here.

This release: `check.ps1 -Full` green; the server suite 836 passed / 1 skipped on Windows and 807 passed / 30 skipped natively on Linux (WSL); the desktop suite 281/281. The empty-reply fix and both desktop-key fixes were each reproduced on the old build and shown fixed on the new one.

## Known limits

- **Whether a lineage gets better is not yet measured.** A first lineage benchmark (fresh casts against a lineage left alone and a lineage whose proposals are all kept, four casts each) scored every arm the same, because its own hidden cases checked two rules its task never stated. Review is a manual step for that reason; nothing is promoted automatically.
- The Cloudflare tool-belt simulation could not be scored on this release: under its containment settings every model call failed with `curl: (3) No host part in the URL`, not yet explained.
- The desktop's lineage cards are covered by tests of their data and requests, not by a look at the screen.

## Install or update

From **v1.1.3** or later, finish active work and choose **Settings → Updates → App updates → Update & restart**.

For a first installation, or from v1.1.2 and earlier, download and extract the full bundle for your platform:

| Platform | Full desktop bundle |
| --- | --- |
| Windows x86_64 | `veil-v1.1.5-windows-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.5-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.5-macos-x86_64.zip` |
| Linux x86_64 | `veil-v1.1.5-linux-x86_64.zip` |

Run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep `veil-install.txt`, the memory engine in `bin/`, and your existing data directory. The `veil-update-*` assets are for the built-in updater; GitHub source archives require a compiler.

The bundles remain unsigned. Update verification and recovery behavior are described in the [update guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md).
