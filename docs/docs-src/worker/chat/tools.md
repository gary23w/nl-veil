# tools

**File:** `src/worker/chat/tools.zig`  
**Module:** `worker/chat`  
**Description:** The tool surface a chat turn (and a chat-scoped cast) runs its calls through — file build tools that write into the conversation's shared workdir, plus the `POST /api/v1/chat/tool` handler the desktop shares.

---

## Purpose Summary

`chat/tools.zig` is the chat side of the tool system. It exposes the shared tool endpoint (`chatTool`) and the per-conversation build tools the chat brain's loop invokes, all rooted at the conversation's own workdir (`{data}/u{uid}/_chat/builds/{conv}`) so a chat turn and a hive cast for the same conversation co-edit one tree with one micro-VCS history. Path handling is structural — `safeSeg` reduces any conversation id to one safe path segment under the caller's `uid` — so a tool call can only ever touch its own conversation's files.

## Key surfaces

- `chatTool` — the `POST /api/v1/chat/tool` handler; one shared tool surface for the desktop and the chat brain.
- `safeSeg` — sanitize a conversation id into a single alnum/`-`/`_` path segment (mirrored verbatim by `chat/service.zig` and `sched.zig`, so a conv addressed anywhere resolves to the same tree).
- The build-tool implementations (write / read / edit / list) that route through the conversation workdir and the shared micro-VCS.

## Dependencies

- `worker/tools` — the underlying tool dispatch and execution
- `worker/vcs` — the micro version-control that reconciles concurrent edits to one file
- `gateway/http` — request helpers and the App context

## Usage Context

Called by `chat/engine.zig` during a turn and by the desktop over the shared tool endpoint. The SAFE/ADMIN split is the intended seam for per-role tool gating; until that lands the chat turn is admin-only (see `chat/service.zig`).

---

*Documentation generated for nl-veil — worker/chat/tools.zig source analysis.*
