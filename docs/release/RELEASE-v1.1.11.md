# the veil v1.1.11

Chat keeps answering when a hosted model changes how it treats a request. A long turn that reaches its spend ceiling now carries its findings into the next stretch even when the model wrote them into its reasoning channel, the desktop stops dialing an endpoint it never had on the Cloudflare login and folds your message into a turn that is still running, and the survey and planning passes before an answer show their reasoning in the chat as they think.

## What changed

- **A dead thinking-off setting stays retired.** The engine learns, per model, which request setting silences hidden reasoning on its auxiliary calls. When a provider stops honouring the learned setting, the engine drops it and tries the next candidate, and that decision is now written to the quirk store together with the trial position. Before, the save re-read the old lesson from disk and put it straight back, so the same dead setting was sent on every call, and on Workers AI's glm-5.3-flash those replies came back with empty content.
- **The continuation state is read from the reasoning channel when the content is empty.** A turn cut at the spend ceiling asks the model for a short state to continue from. Some servings answer that request inside the reasoning field and leave the content blank, which used to commit the bare "context was COMPACTED" note and restart the next turn from nothing. The engine now takes the last labelled draft from the reasoning field.
- **The desktop no longer calls a model it cannot reach.** With the Cloudflare login and no account id set, the desktop's own engine resolved to a placeholder that only the server understands, and every local call died within seconds, twice per turn, then again on each auto-loop step. The desktop now refuses that call with one plain message, switches its local auto-loop off instead of retrying it every frame, and does not arm the 45-second server cooldown when it has nothing to fall back to.
- **A message sent while a turn is still running joins that turn.** When the server answers that the conversation already has a turn in flight, the desktop steers your text into it and watches the turn, instead of starting a second engine beside it and losing the message.
- **The survey and planning passes show their reasoning.** The status line used to read "surveying before planning" or "planning the work" over an empty chat while the model thought. Both passes now stream their reasoning into the chat the way the answer does. Their own output, a probe list and a plan board, is still parsed by the engine and never shown as a reply.

## Verification

Server and desktop regression tests cover the quirk store keeping a retired setting retired through a merge with a stale file and across processes, the continuation state read from the last labelled draft of the reasoning field, the desktop's placeholder check, and the rule that every pre-answer pass sends a bounded prompt and streams only its reasoning. The provider change itself was measured from the dataset capture: the same request shape was answered silently on every call through October 1 and with reasoning on every call from October 5, and the calls carrying the setting were the ones that came back empty.

The release workflow runs the full acceptance checks and packaged-app smoke checks on Windows, Linux and both macOS architectures before publication.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a first installation, download the full bundle for your platform from the [v1.1.11 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.11), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep the complete bundle together and preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.10...v1.1.11) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)
