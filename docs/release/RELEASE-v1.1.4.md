# the veil — v1.1.4

A calmer desktop for longer tasks, with clearer progress, organized settings, and more stable streaming chat.

## What changed

- **Visible preparation.** Chat shows preparation status before provider setup and history loading, then displays the server's available planning and execution updates above the conversation.
- **Steadier streaming.** Bottom-follow absorbs small layout changes that caused the conversation to bounce while text arrived. Manual scrolling and deliberate expansion still use the actual content bounds.
- **Organized settings.** General, Models, Connection, Data, and Updates have their own pages, with wrapped descriptions and a centered layout. Scrolled controls cannot intercept clicks behind the navigation.
- **Cleaner messages.** Code blocks have separate headers, wrap long lines, and preserve the original text when copied. Longer and tilde fences are handled correctly, including unfinished streamed blocks.
- **A more welcoming start.** New chats offer editable starter prompts. Focused idle rendering and text reveal respond sooner, and layout caches invalidate when the conversation or display dimensions change.
- **Reliable HTTP completion.** Both desktop and server clients distinguish a completed request timer from a real deadline, preventing a race that could report a false timeout. Late responses are cleaned up.

## Install or update

From **v1.1.3**, finish active work and choose **Settings → App updates → Update & restart**. In v1.1.4, the updater lives under **Settings → Updates → App updates**.

For a first installation, or from v1.1.2 and earlier, download and extract the full bundle for your platform:

| Platform | Full desktop bundle |
| --- | --- |
| Windows x86_64 | `veil-v1.1.4-windows-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.4-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.4-macos-x86_64.zip` |
| Linux x86_64 | `veil-v1.1.4-linux-x86_64.zip` |

Run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep `veil-install.txt`, the memory engine in `bin/`, and your existing data directory. The `veil-update-*` assets are for the built-in updater; GitHub source archives require a compiler.

The bundles remain unsigned. Update verification and recovery behavior are described in the [update guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md). See the [desktop guide](https://gary23w.github.io/nl-veil/#doc=guide/desktop) for the new layout and controls.
