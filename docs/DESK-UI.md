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

The Hots tab lists the account's hots (at most three, the first named Gary) on the
left, above the scratchpad they share: entries wrap and scroll, newest at the bottom,
and a two-click *clear* empties it for the next set of hots. The right side is the
selected hot: its goal and counters, Pause / Resume, Shrink / Grow, **Open folder**
(its local run folder: `events.log`, notes, status), a two-click Delete, the event
console and one line that sends it a message or a command. The console wraps every
event and scrolls with the wheel or its bar; scrolling up stops it following, and
*latest* (or scrolling back down) follows again. Under the Deploy button one line names the tools the
account's hots have (Python and the browser are there when the account took them),
and why not when one is missing. "Deploy a hot" replaces the right
side with the deploy form: PACE runs from every 5 seconds to every 6 hours and MODEL
CALLS A DAY ends in *unlimited*; MODEL is a list of the account's live Workers AI models,
the goal and charter count against what that model can carry, and the last box,
"let it use THIS machine", starts unchecked on every new form. The tab asks the
server for the roster, the events and the scratchpad only while it is on screen.

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
- With a Cloudflare login, open Hots, deploy one, and watch its console fill. Scroll
  up, check that long rows wrap and stay put, then press *latest*. Send it a message
  and `/pause`; Grow and Shrink it; open its folder; click Delete once, click
  elsewhere, and confirm nothing was deleted. Open the form again: the machine box is
  unchecked, the MODEL list shows the account's models, and a goal past the counter
  disables Deploy.
- Copy code from backtick, tilde, nested, and unfinished fences. Compare with the
  original bytes, including tabs and Unicode.

Run `zig build` at the repository root and `zig build test` inside `desk` for build
and regression checks. Live-service tests may skip when their services are absent;
these checks do not replace a visual review of the native window.
