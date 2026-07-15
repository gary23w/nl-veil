# service

**File:** `src/worker/deploy/service.zig`  
**Module:** `worker/deploy`  
**Description:** The swarm door: the deploy/cast REST handlers that turn a goal into a running hive, plus the routes that read and manage a swarm's files, bundle, archive, and lifecycle.

---

## Purpose Summary

`deploy/service.zig` is the HTTP surface for deploying and managing swarms. It accepts a goal (with optional minutes / minds / model / provider / style / mode), asks the supervisor to detach a worker, and returns the new swarm id. It also serves everything a client needs to watch and collect a run: the file list, individual files, a downloadable bundle/archive, an in-place file PUT, and the swarm's static site preview; and it deletes a swarm's tree.

## Routes

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/v1/cast` | deploy a swarm to work a goal → `{id,…}` |
| `POST` | `/api/v1/run` | one-shot run entry |
| `POST` | `/api/v1/swarms` | deploy (sustained hive) |
| `POST` | `/api/v1/swarms/resolve` | resolve a swarm spec |
| `GET` | `/api/v1/swarms` | list the caller's swarms |
| `GET` | `/api/v1/swarms/:id/files` · `/file` · `/bundle` · `/archive` · `/site/*` | read a run's deliverables |
| `PUT` | `/api/v1/swarms/:id/file` | write a file into a run in place |
| `POST` | `/api/v1/swarms/:id/deploy/cloudflare` | deploy a run's site |
| `DELETE` | `/api/v1/swarms/:id` | remove a swarm's whole tree |

## Dependencies

- `worker/control/supervisor` — detaches and tracks the worker process
- `worker/control/fanout` — the events surface the run streams to
- `gateway/http` — request/response helpers, structural ownership under the caller's uid

## Usage Context

The engine behind `veil cast` / `veil deploy` / `veil list` / `veil rm` and the desktop's swarm board. `deploy` is `cast` with `mode: "continuous"` (a sustained hive). Ownership is structural: a swarm id resolves only under the caller's own registry entry.

---

*Documentation generated for nl-veil — worker/deploy/service.zig source analysis.*
