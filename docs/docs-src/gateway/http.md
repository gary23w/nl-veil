# http

**File:** `src/gateway/http.zig`  
**Module:** `gateway`  
**Description:** The HTTP gateway: the shared `App` context, the auth guard every handler calls (`requireUser` / `isAdmin`), and the small JSON/file helpers handlers build responses with. The route table itself is registered in `src/main.zig`.

---

## Purpose Summary

`gateway/http.zig` is the ingress plumbing every route shares. It defines `App` (the server-wide context — data dir, io, allocator, auth, supervisor), the request guards handlers gate on (`requireUser` resolves the caller from the bearer/session; `badReq` / `notFound` / `serverErr` shape errors), and the byte-level helpers (`jstr` for JSON-escaping into a buffer, `appendFile` for durable JSONL appends). Handlers across `auth/`, `worker/`, `plan/`, and `admin/` are thin functions over this surface; the router in `main.zig` maps paths to them.

## The route table

Registered in `main.zig`. The chat and scheduled-task surfaces are the ones a thin client drives:

| Method | Path | Handler |
|---|---|---|
| `GET` | `/api/v1/health` · `/api/v1/fleet` | health, fleet summary |
| `POST` | `/api/v1/cast` · `/api/v1/run` · `/api/v1/swarms` | deploy a swarm (`worker/deploy/service`) |
| `GET` | `/api/v1/swarms` · `/api/v1/swarms/:id/events` · `/stream` · `/files` · `/file` … | read a run (`deploy/service`, `control/fanout`) |
| `POST` | `/api/v1/swarms/:id/control` | steer a swarm (`control/writer`) |
| `DELETE` | `/api/v1/swarms/:id` | remove a swarm |
| `GET` | `/api/v1/chat/convs` | list conversations (`worker/chat/service`) |
| `GET` | `/api/v1/chat/convs/:id` | read a conversation's messages |
| `DELETE` | `/api/v1/chat/convs/:id` | delete a conversation |
| `GET` | `/api/v1/chat/convs/:id/events?from=N` | stream a turn's event frames (cursor) |
| `POST` | `/api/v1/chat/convs/:id/messages` | run one server-side chat turn |
| `POST` | `/api/v1/chat/convs/:id/control` | stop / steer a running turn |
| `POST` | `/api/v1/chat/tool` | the shared tool endpoint (`worker/chat/tools`) |
| `GET` | `/api/v1/sched` | list scheduled tasks (`worker/sched`) |
| `POST` | `/api/v1/sched` · `/api/v1/sched/:id` · `/api/v1/sched/:id/run` | create / update / run a task |
| `DELETE` | `/api/v1/sched/:id` | delete a task |
| `POST`/`GET` | `/api/v1/auth/*` · `/api/v1/apikeys` · `/api/v1/keys` | auth, API keys, provider keys |
| `GET`/`POST`/`DELETE` | `/api/v1/admin/*` | admin surface (users, billing, moderation, audit) |

The server also serves the bundled web control-plane UI at `/`, `/app.js`, `/styles.css`, `/models.json`.

## Dependencies

- `auth/auth_core` — resolves and authorizes the caller behind `requireUser` / `isAdmin`
- `httpz` — the underlying HTTP server (blocking worker model, thread-per-request)
- Standard library: io, fmt, mem

## Usage Context

Sits at the ingress boundary. Every handler takes `*App` and the `httpz` request/response, guards with `requireUser` (and `isAdmin` where a route is admin-only — scheduled tasks and the admin console; chat turns are open to every authed user and gated by capability inside the turn instead), then reads/writes under the caller's own `u{uid}` prefix — ownership is structural, not a per-request check against a registry.

## Notable Implementation Details

The server runs `httpz`'s blocking worker model with a large thread pool, so one slow synchronous spawn can't wedge admission. Keep-alive is ON — connections are reused for up to `NL_KEEPALIVE_REQUESTS` (default 200) with a 60s idle reap and a 15s request timeout — because the web client polls, and a fresh TCP handshake per poll is a cost a LAN of browsers pays continuously.

The server ALWAYS mints an admin API key and drops it at `{data}/.desktop_key`, which the desk and the `veil` CLI read to authenticate with zero prompting. This used to be conditional on a localhost bind; gating it meant that turning on network access silently broke every same-machine client, so the condition was removed.

---

*Documentation generated for nl-veil — gateway/http.zig source analysis.*
