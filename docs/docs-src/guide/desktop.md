# Desktop experience

Settings has five pages with fixed navigation and a scrollable content area:

| Page | Controls |
| --- | --- |
| General | Text size, accessibility, notifications, and task behavior |
| Models | Chat provider, model roles, Cloudflare login, and built-in model installation |
| Connection | Server address, port, API token, and data location |
| Data | Dataset recording |
| Updates | Release checks and installation |

New chats offer starter prompts that fill the composer for editing. They do not
send automatically.

While a task runs, the progress card above the transcript displays the current
server status, including surveying, planning, and choosing the next step. It stays
visible when reading earlier messages. Preparation is shown before provider,
attachment, and history setup completes. These are actual status events; the UI
does not invent steps or completion percentages. Streamed reasoning continues to
appear in the conversation.

Bottom-follow keeps a small reading cushion while streaming Markdown reflows, so
losing a wrapped line does not pull the transcript back down. Empty live replies
do not create a temporary message row. Scrolling, resizing, and manually folding
a section still use the current content bounds.

Fenced code has a separate language and copy header. Long lines soft-wrap to fit
the chat pane; copying preserves the original text, indentation, and line endings.
Both backtick and tilde fences are supported, including longer fences surrounding
shorter examples and incomplete blocks during streaming.

## Manual review

- Open each settings page at normal and XL text sizes. Scroll with the wheel and
  scrollbar; check that content cannot be clicked behind the navigation.
- Change notifications and the connection token, restart, and verify persistence.
- Select a starter, edit it, and send. Confirm preparation and server phase updates
  appear before the first response token and disappear after completion or Stop.
- Read older messages while a long task runs; the progress card should remain
  visible without forcing the transcript to follow new output.
- Resize the chat pane while streaming prose, tables, and long code. Change text
  size and font; verify message spacing recalculates.
- Copy code from backtick, tilde, nested, and unfinished fences. Compare with the
  original bytes, including tabs and Unicode.

Run `zig build` at the repository root and `zig build test` inside `desk` for build
and regression checks. Live-service tests may skip when their services are absent;
these checks do not replace a visual review of the native window.
