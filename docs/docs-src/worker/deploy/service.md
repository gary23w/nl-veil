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
| `POST` | `/api/v1/admin/billing` | admin-only plan change or neuron top-up |
| `POST` | `/api/v1/swarms/resolve` | resolve a swarm spec |
| `GET` | `/api/v1/swarms` | list the caller's swarms |
| `GET` | `/api/v1/swarms/:id/files` · `/file` · `/bundle` · `/archive` · `/site/*` | read a run's deliverables |
| `PUT` | `/api/v1/swarms/:id/file` | write a file into a run in place |
| `POST` | `/api/v1/swarms/:id/deploy/cloudflare` | deploy a run's site |
| `DELETE` | `/api/v1/swarms/:id` | request a running metered swarm to stop, then remove it after final usage settles |

## Dependencies

- `worker/control/supervisor` — detaches and tracks the worker process
- `worker/control/fanout` — the events surface the run streams to
- `gateway/http` — request/response helpers, structural ownership under the caller's uid

## Usage Context

The engine behind `veil cast` / `veil deploy` / `veil list` / `veil rm` and the desktop's swarm board. `deploy` is `cast` with `mode: "continuous"` (a sustained hive). Ownership is structural: a swarm id resolves only under the caller's own registry entry.

Admin billing accepts either a plan change or a top-up in one request. A top-up requires `email`, positive `topup`, and a caller-generated `topup_id` in the form `t<unix-seconds>_<unique nonce>`. Keep that ID stable when retrying an uncertain request within 90 days; generate a new ID for a separate grant. The suffix needs at least eight ASCII letters, digits, hyphens or underscores; the whole ID is at most 64 characters. Reusing an ID with a different amount returns 409. A missing, malformed, expired, or more than five-minutes-future ID returns 400.

Each deploy gets a fresh `billing_run_id` in its manifest and initializes `.usage` for that ID before spawn. A re-cast in a reused chat directory must settle a tracked prior report before replacing it. Production deploys meter existing runs and recheck the caller's balance immediately before spawn. A DELETE of an active metered worker returns HTTP 202 with `stopping: true` and `deleted: false`; retry after it writes `DONE` to settle its final report and remove the run. An unconfirmed settlement returns a server error and leaves the report available for retry.

---

*Case file grounded in the module's `//!` header and public API.*

## Security tools in v1.1.12

The deployment request includes a separate `garrett` opt-in. When enabled, it resolves the authenticated user’s deployment and writes the MCP URL/token into the swarm’s existing key material for its workers. A deployment without this opt-in does not receive that credential pair.

[Security deployment and use guide](../../guide/security-tools.md).
