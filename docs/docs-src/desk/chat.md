# chat

**File:** `desk/src/chat.zig`  
**Module:** `desk`  
**Description:** The veil-desk Chat tab client and renderer — it sends a message to the server-side chat brain, streams the turn's event frames back into the UI, and steers or stops a running turn. The agentic loop itself now lives in the backend (`src/worker/chat/engine.zig`), not here.

---

## Purpose Summary

chat.zig is the desktop's chat worker thread (beside the UI and the poller), owning its own std.Io and communicating with the UI only through a locked Store. It is a **thin client** over the server chat brain: a user message is POSTed to `/api/v1/chat/convs/:id/messages`, the turn's frames are streamed from `/events`, and a line typed while a turn runs — or the Stop button — becomes a `/control` op (`steer` / `stop`) the running server turn folds in. The heavy machinery — the tool-calling loop, casting, the auto-loop drive, the neuron-db learning harness — runs server-side in `worker/chat/engine.zig`; the desk's job is to send, render, and steer.

The desk prefers the backend turn and **falls back to its own local engine** on any failure (a `501` from the kill switch `VEIL_CHAT_BACKEND=0`, a non-2xx, or an unreachable server), so the Chat tab keeps working even when the backend is disabled. It also owns chat-side presentation: conversation selection, streaming/render of the frames, the memory/proposal panes fed by the server, and settings.

## Key Exports

- `Chat` (struct) — the chat client: state fields + methods; instantiated once and `run()` on its own thread
- `Chat.run` — the ~10Hz tick loop: drains UI commands, drives the send/stream/steer flow against the server, publishes render state
- `Chat.cmdSend` — entry for a user message: POSTs it as a turn to the server chat brain, arms the auto-loop tier for the conversation
- `Chat.cmdStopCast` / control helpers — post `{"op":"stop"}` / `{"op":"steer",…}` to the running turn's `/control`
- conversation lifecycle + message-render primitives that mirror the server's `messages.jsonl` / `events.jsonl` shape

## Dependencies

- store.zig (Store — the lock-guarded shared UI/state surface)
- llm.zig (streaming client — used for the LOCAL fallback engine when the backend is unavailable)
- netcli.zig (in-process server calls: POST the message, poll `/events`, POST `/control`)
- scan.zig (filesystem-first cast watching for the swarm board)
- neuron.zig (neuron-db bridge — used by the local fallback; the server owns memory for backend turns)
- httpc.zig (curl-free loopback HTTP), catalog.zig, secrets.zig, log.zig, std.Io, builtin

## Usage Context

Instantiated once and launched on its own thread at app startup. The UI thread never calls its methods directly — it pushes typed commands into a Store queue (send, new/select/rename/delete conv, stop_turn, steer, loop_kick, save_settings/key) which the tick loop consumes. It talks to the running nl-veil server on :8787 for the whole chat flow; when that backend is unreachable or disabled it degrades to the bundled local engine rather than failing.

## Notable Implementation Details

The server owns the turn: one in-flight turn per conversation (the server answers `409` on a racing send), the tool loop, the auto-loop drive tiers (off / on / afk, passed as `loop: 0|1|2` on the message body), and the learning harness all run in `worker/chat/engine.zig`. The desk streams the turn's frames positionally from the `/events` cursor and renders assistant tokens, tool starts, and status lines. Steering is cooperative: a line typed mid-turn is posted as `{"op":"steer","text":…}` and folded in server-side without restarting the turn; Stop posts `{"op":"stop"}`.

The **local fallback engine** is the desk's own earlier chat brain, kept as a resilience path: if the backend turn can't be used it runs the turn locally (its own stream, tool recovery, and neuron-db scopes). This is why the desk still bundles llm.zig and neuron.zig even though the backend normally does the work.

---

*Case file grounded in the module's `//!` header and public API.*
