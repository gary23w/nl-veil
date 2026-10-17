# the veil v1.1.23

A chat no longer carries a compressed copy of its past. Every message is stored as it lands, and every request is built from that store: the turn's prefix, Gary's 4tope laid out over everything said and found earlier in the conversation, and the newest rounds word for word. This release also fixes a failure where a model's self-heal cut the turn's own instructions open and the chat lost its place for the rest of the turn, and Claude models since Opus 4.7 answer again.

v1.1.22 was never published (one bundle failed to build). Its changes ship here and are listed at the end.

## What changed

- **Every request is unfolded from the conversation's store.** Each message lands in the conversation's `graph.jsonl` the moment it exists: the ask, each step and its calls, each tool result as the model saw it, each answer. Each tool result's payload is also indexed in neuron-db as a document of its own. A request is then the turn's prefix, one net laid out over every earlier ask, answer and result from where the work stands, and the newest two rounds verbatim. Nothing older is summarized, folded or carried, and the request stays the same size however long the chat runs. A word a later step uses links it to the earlier result that holds it, so a value found many turns ago comes back when it is needed. The net names each node by id, and a new `recall_node` tool returns any of them whole. A result that looks like a credential is stored as a stub and indexed nowhere. `NL_CONTEXT=fold` restores the fold-and-carry path.
- **A self-heal can no longer cut the turn open.** When a provider demands that a model's reasoning be passed back on earlier messages, the engine adds that field to every assistant message, including the ones in the turn's fixed prefix. The turn kept the prefix's end as a byte position, so the next fold or roll cut 23 bytes short of it: on 2026-10-16 that cut the turn's brief open mid-word, and every later request was malformed. The provider rejected each one, and the engine's last-resort repair then sent only the start of the conversation, without the brief, the subtask or any tool result, for about 70 calls. The prefix's end is now kept as a message count. Every cut lands between two messages or moves to the next boundary, and says so. The conversation is checked before every request: a message that does not parse is dropped from the conversation itself, loudly, and the rest is kept, with invalid text bytes repaired rather than dropped. A conversation with nothing left that parses stops with an error instead of sending what it no longer has. The provider-side repair keeps every message that parses instead of everything before the first broken one, and announces itself.
- **The store never keeps a broken message.** A message that does not parse is refused and the chat says so; a line torn by a crash mid-write is skipped when the store loads.
- **Claude models since Opus 4.7 answer again.** Anthropic now rejects any request that sets `temperature` on those models ("temperature is deprecated for this model."), and every chat with one failed on its first call. That reply is now read as a learned quirk: the field is dropped, the request goes again, and the model is remembered so later calls never send it. The model catalog adds Claude Opus 5.5 (the new Anthropic default), Sonnet 5.5 and Haiku 5.5.

## Also in this release (from the unpublished v1.1.22)

These shape the fold-and-carry path, which `NL_CONTEXT=fold` restores:

- The spend ceiling stops being the compactor: the default is at least a dozen of the fullest prompt a turn may send, and cached prompt tokens count a quarter. An explicit `NL_TURN_TOKEN_CEILING` is honoured as written.
- The fold inside a turn is Gary's 4tope instead of a model-written summary, so a long turn folds with no model call. `NL_HANDOFF=model` restores the summary.
- A carry holds what the tools showed (a tool's output, not its JSON envelope), is sized to the model's window, carries what earlier passes established, and reaches the next turn through the conversation's `net.jsonl`.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release tree: model-catalog sync, web assets, the Taters runtime suite, the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the merged desktop build. The server test suite ran 1,025 tests with one platform skip, and the desktop suite 308.

A scripted live run reproduced the 2026-10-16 failure on real servers with a stand-in model that, like the provider involved, rejects a request until the reasoning field is passed back and rejects a body that is not valid JSON, under a spend ceiling small enough that the turn rolls. v1.1.22 sent 16 malformed requests in that turn and answered each from the same few kilobytes at the start of the conversation, with no tool result in them. This release sent none, on the store and on the fold-and-carry path alike, and traced the prefix moving 23 bytes under the heal while every cut followed it. On the store path every request carried the net and the newest two rounds, and the conversation's `graph.jsonl` filled as it ran. A separate scripted run planted facts mid-file in tool output, ran a dozen unrelated turns, then asked about each fact: the store brought every one back into the request, and the fold-and-carry path none.

The Claude fix was checked against a stand-in that answers Anthropic's exact rejection; a live call to a Claude 4.7+ model has not been made from this build.

Not yet verified: a long chat on a real hosted model with the store as the default, how prompt caching treats a request whose middle changes every round, and the new status lines in the desktop.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). For a new installation, download the complete bundle from the [v1.1.23 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.23), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.21...v1.1.23) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## Licenses and corresponding source

NL-Veil app code is licensed under MIT. Dependencies and separately distributed components retain their own licenses. Current security-tool integration connects to an external service through an API key.
