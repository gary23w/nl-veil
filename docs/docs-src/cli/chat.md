# chat

**File:** `src/cli/chat.zig`  
**Module:** `cli`  
**Description:** The interactive `veil chat` REPL — it drives the server-side chat brain over the same REST surface the desktop uses.

---

## Purpose Summary

A line-oriented loop: read a message from stdin, POST it to `/api/v1/chat/convs/:id/messages` as a fresh turn (`loop:0`), then stream the turn's frames to completion via the injected `followConv`. `/stop` posts `{op:"stop"}` to the conversation's `/control` route, `/new` mints a fresh conversation id, `/quit` (or EOF) leaves. Every send carries `tool_client:true` — client mode — so the server delegates tool calls back to this process and they run on the user's machine. The header describes a typed line during a run becoming a steer; in the current code the turn streams to completion before the next prompt accepts input (the mid-turn background reader is noted in-code as a future refinement).

## Key Exports

- `run` — the whole REPL. Takes `Ctx` plus `call`, `followConv`, `ensureServer`, and `unreachable_msg` injected from cli.zig, so this file never re-implements the HTTP path — it composes the chat flow on top of them.

## Dependencies

- `../cli.zig` — `Ctx`, `CallFn`, `out`; the HTTP plumbing arrives as function parameters rather than imports

## Usage Context

Reached only through `cli.zig`'s `cmdChat` (the `veil chat [conv]` verb). The conversation id is the first non-flag argument, else a client-minted `cli<12 hex>` id the server creates a directory for on first message.

## Notable Implementation Details

- Provider fields come from the environment: `NL_LLM_BASE_URL` (defaulting to a local Ollama, `http://127.0.0.1:11434/v1`), `NL_LLM_MODEL` (default `gpt-oss:20b`), `NL_LLM_KEY`.
- The optional model trio rides the same message body: `NL_LLM_THINK_*` (plan/reflect/compact/ctxsum/summary/lesson) and `NL_LLM_PROMPT_*` (one-line drive steps). Unset roles are sent as `""` and the server falls back.
- The banner names the ROLE each model carries, and when no trio is set it deliberately does not claim those roles run on the coding model — the server may fill a blank role from the host's published trio, and the CLI cannot know which happened without asking.
- `readLine` reads stdin one byte at a time through std.Io — fine for a line-oriented REPL; EOF (Ctrl-D / closed pipe) ends it.

---

*Case file grounded in the module's `//!` header and public API.*
