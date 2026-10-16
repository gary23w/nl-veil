# the veil v1.1.22

A long chat no longer compacts itself every few calls and loses track of what it just did. Gary's 4tope, which in v1.1.16 wrote the continuation when a turn crossed its spend ceiling, now does the folding inside a turn too. What it carries is what the tools actually showed, sized to the model's window, and it reaches the next turn.

## What changed

- **The spend ceiling stops being the compactor.** On 2026-10-14 a long chat on a model with a 262k-token window was cut after 27 calls whose largest prompt was 21.6k tokens: the ceiling counts every call's prompt, and the working span a turn may hold had grown with the window while the ceiling had not. A wider window was cut sooner than a narrow one. The default ceiling is now at least a dozen of the fullest prompt the turn may send, and cached prompt tokens count a quarter, the way providers bill them. An explicit `NL_TURN_TOKEN_CEILING` is still honoured as written.
- **The fold is the net.** When a turn's working context outgrows its budget, the older rounds become one note laid out by Gary's 4tope: the results the work rests on, the calls that failed, and what an earlier fold carried, every line verbatim from a tool result. The newest rounds stay whole. This replaces a model-written summary on every fold, so a long turn folds with no model call. `NL_HANDOFF=model` restores the summary.
- **A carry holds what the tools showed.** A tool that answers in a JSON envelope is carried by its output, not the envelope's first bytes: on that 2026-10-14 chat every carried line had been a shell tool's cursor and status fields with none of the output. The results the work rests on, and the result of the call the turn had just made, ride whole up to 3,000 characters; the rest are short excerpts.
- **A carry is sized to the window.** The continuation a turn writes when it crosses the ceiling now scales with the model: about 3 KB at a 32k window, 24 KB at 262k, 32 KB at 1M. A small local model keeps the size it had.
- **Passes remember each other.** A turn that crosses the ceiling several times now carries what every earlier pass established and ruled out, failed calls first. Before, each pass knew only its own work.
- **Turns remember each other.** Each finished turn that used tools, and each turn the engine had to settle, leaves its net in the conversation's `net.jsonl`. The next turn reads it back, newest first, as work from earlier turns. The rolling summary only ever saw the conversation's messages, where tool results never land.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release commit: model-catalog sync, web assets, the Taters runtime suite, the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the merged desktop build. The server test suite ran 1,026 tests with one platform skip.

A scripted live run drove a real server built from this release with a stand-in model. It saw a long turn fold into the net with no model call while its prompts stayed bounded. It saw a turn cross a deliberately small ceiling, carry on twice and settle, with every carry written by the net. Each later carry held what the earlier passes established, the latest result arrived whole, and the next turn read the earlier turn's net. That run found two gaps the unit tests missed, both fixed before this release: the result of the call the turn had just made was carried as a short excerpt, and an earlier pass's result carried whole crowded out every older line.

Not yet verified: a long chat on a real hosted model, and the new status lines in the desktop.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). For a new installation, download the complete bundle from the [v1.1.22 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.22), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.21...v1.1.22) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## Licenses and corresponding source

NL-Veil code is licensed under MIT. The Gary security runtime is licensed under AGPL-3.0. Its source archive and Cloudflare build sources are available in the repository and included in full release bundles. Dependencies retain their own licenses.
