# cli

**File:** `src/cli.zig`  
**Module:** `cli`  
**Description:** The `veil` command-line client — every subcommand is a thin authenticated call to the local server's `/api/v1/*` over the in-process httpc socket client, retiring the old Python launcher (deploy.py) and fleet tool (hub.py).

---

## Purpose Summary

One dispatcher for every CLI verb: swarms (`cast`/`deploy`/`list`/`stop`/`rm`/`events`), chat, sched, hub, doctor, desktop, rag, themes, plugins, and the exec-tool/sync verbs. The server is the one daemon that owns swarms, the chat brain, and scheduled tasks; the CLI never boots it in-process — a verb that needs it auto-starts a detached daemon (`--server-only`, so no GUI window pops) and waits up to ~15 s for `/health`. Auth is zero-prompt on the same machine: the server drops an admin API key at `{data}/.desktop_key` on any localhost bind and the CLI sends it as the bearer. The file also carries the CLI side of client mode: `followConv` tails a chat conversation's frames and executes delegated `tool_request` / `sync_request` / `file_pull` / `file_sync` frames on the user's machine, posting results back so the blocked server turn continues.

## Key Exports

- `Ctx` — everything a subcommand needs: gpa, io, data/home dirs, port, environ, and the loaded `.desktop_key` token
- `isCommand` — is this argv token a CLI verb? (main.zig falls through to the server boot otherwise, keeping bare `veil` = run the app)
- `dispatch` — run one subcommand (argv after the verb), returning the process exit code
- `CallFn` / `HttpError` — the HTTP-call function type + error set re-exported for the chat/hub subcommand files
- `followConv` — tail a chat conversation's events by byte cursor, rendering frames and running delegated tools, until a `{done}` frame
- `out` — printf to STDOUT (results survive a pipe; errors/usage stay on stderr)
- `jsonStr` / `jsonNum` / `JsonObjs` — string-aware flat-JSON field readers + an envelope-array object iterator (no full parse)

## Dependencies

- `worker/httpc.zig` — the socket HTTP client every call rides (no curl, no argv secrets)
- `cli/exec_tool.zig` — the shared tool executor (`exec-tool`, `sync-*` verbs; delegated tool runs)
- `cli/chat.zig` / `cli/hub.zig` — the substantial subcommands, kept in sibling files with thin entry points here
- `worker/chat/sync.zig` — safe-root/safe-path checks + manifest/read responses for workdir sync frames
- `worker/chat/toolperf.zig` — the engine's learned tool digest, reused by `doctor --growth`
- Lazily per verb: `worker/ragmirror.zig`, `worker/ragingest.zig`, `worker/oscillation.zig`, `worker/tools.zig` (rag), `plug/theme.zig` (the frozen slot_names for `themes <id>`)

## Usage Context

`main.zig` routes a recognized verb here (`cli.isCommand` → `cli.dispatch`) and exits with its code; anything else boots the server/app. `cli/chat.zig` and `cli/hub.zig` call back through the injected `call` function so there is exactly one HTTP path.

## Notable Implementation Details

- `deploy` is `cast` with `--continuous` implied; `--lineage <id>` persists swarm memory so re-casts compound.
- `doctor --growth` reads `{data}` directly on purpose — the report (toolperf digest, sched fail-streaks, per-model llm.jsonl rollup) works with the server down.
- `followConv` only consumes up to the last COMPLETE line of a 512 KB events page: advancing the cursor over a torn `tool_request` frame would leave the turn blocked forever.
- `cmdDesktop` relaunches THIS executable detached (the GUI is compiled in; there is no separate desk binary anymore).
- `themes` needs no auth (public endpoint); `plugins` needs the admin key — a 401/403 on the read exits clean with a tailored note, on `reload` it exits 1.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
