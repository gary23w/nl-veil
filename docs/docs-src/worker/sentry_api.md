# sentry_api

**File:** `src/worker/sentry_api.zig`
**Module:** `worker`

The two surfaces of the [sentry](sentry.md) that need the App: its admin routes and its background thread. The sentry itself is std-only; this file is the glue.

## Routes

| Route | Reply |
| --- | --- |
| `GET /api/v1/sentry` | the status object with the open findings spliced in (`findings`, newest last, up to 40) |
| `POST /api/v1/sentry/scan` | an inventory now; the status after it |
| `GET /api/v1/sentry/findings?since=&min=&limit=&all=1` | `{ok, acked, findings}`; without `all=1` only unacknowledged findings |
| `GET /api/v1/sentry/inventory` | the last inventory: listeners (with `exposed` and `own`), connections (with `public`), persistence entries |
| `GET /api/v1/sentry/rules` | `{ok, posture, rules}` |
| `POST /api/v1/sentry/rules` | add (body: `sentry.RuleSpec`); 201 `{ok, id, posture, last_error}` or 400 with the refusal |
| `DELETE /api/v1/sentry/rules/:id` | `{ok}`; 404 when absent |
| `POST /api/v1/sentry/set` | `{enabled?, posture?, auto_block?, every_s?, allow_port?, disallow_port?, baseline?, ack?}`; the status after it |

Every route calls `requireAdmin` first: the sentry reads this machine and, in the enforce posture, changes its firewall. A server built without a sentry (`http.testApp`, a worker) answers 503 after the gate. Rule changes and posture switches are recorded in the audit log under the admin's email.

## The thread

`bgLoop` sleeps fifteen seconds after boot (so the listener, the engine endpoint and the tunnel are in the first inventory), then scans every `every_s` while the sentry is on. Off, it wakes every two seconds to see whether it was switched on, which costs one mutex read. It is a raw `std.Thread` like the scheduler's, so it sleeps with the raw sleep.

## Tests

Every handler, unauthenticated, is refused with 401 before the sentry is consulted; an admin on a server with no sentry gets 503, not a crash. The router audit in `main.zig` reads this file (`ROUTE_MODS`) and checks every `/api/v1/sentry` route points at a gated handler.
