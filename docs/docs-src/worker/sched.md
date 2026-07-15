# sched

**File:** `src/worker/sched.zig`  
**Module:** `worker`  
**Description:** Scheduled tasks that run strictly through chat. When a task comes due the scheduler mints a fresh chat conversation and fires ONE ordinary server chat turn at it — so a scheduled run is a real, resumable conversation, not a separate code path.

---

## Purpose Summary

A task is one JSON file at `{data}/u{uid}/_sched/{id}.json`. When it comes due, the scheduler thread mints a brand-new chat conversation named `scheduled_{id}_{MMDDHHMM}` and fires one normal server chat turn at it via the SAME engine entry points the `/messages` route uses (`tryBeginTurn` + `spawnTurn`). The run therefore persists under `_chat/convs/`, streams events, shows up in the conversation list, and can be continued by hand afterwards. The scheduler owns nothing about how the turn runs — only WHEN the first message is posted.

## The task model (wire contract)

| field | meaning |
|---|---|
| `id` / `name` | task id and human label |
| `prompt` | the message the run posts as its first user turn |
| `kind` | `once` · `every` · `daily` |
| `at` | (`once`) epoch seconds to fire at |
| `every_min` | (`every`) interval in minutes (≥ 1) |
| `hm` | (`daily`) local wall-clock `"HH:MM"` |
| `enabled`, `created`, `last_run`, `next_due`, `last_conv`, `runs` | scheduler bookkeeping |
| `base_url` / `model` / `api_key` | the endpoint the run's turn calls (`api_key` is stored on disk but ALWAYS redacted to `""` over HTTP) |

## Routes

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/sched` | list tasks → `{ok, tasks:[Task,…]}` (api_key redacted) |
| `POST` | `/api/v1/sched` | create → `201 {ok, id}` |
| `POST` | `/api/v1/sched/:id` | partial update → `{ok}` |
| `DELETE` | `/api/v1/sched/:id` | delete → `{ok}` (404 if absent) |
| `POST` | `/api/v1/sched/:id/run` | run NOW → `{ok, conv:"scheduled_…"}` |

All routes are admin-gated exactly like `chat_service.postMessage`: the served chat turn hands the model the full tool surface, so until per-role tool gating lands only the admin may aim it.

## Notable Implementation Details

- **Catch-up policy.** An overdue task (server down, machine asleep) runs ONCE and schedules its next occurrence from now — it never backfills a run per missed interval, so a laptop closed for a week can't fire thousands of turns on wake.
- **Local wall clock.** `daily at HH:MM` uses the machine's UTC offset (queried from the OS each check, so a DST flip mid-uptime is picked up); non-Windows degrades to UTC — a daily task still fires exactly once a day.
- **Raw-thread timing.** The scheduler is a `std.Thread`, not an Io-managed task, so it uses a raw-thread sleep (Win32 `Sleep` on Windows) rather than `io.sleep`.

## Dependencies

- `gateway/http` — `App`, request helpers
- `worker/chat/engine` — `tryBeginTurn` + `spawnTurn` (a due task runs an ordinary chat turn)

## Usage Context

Driven from veil-desk's scheduled-tasks builder and from `veil sched list|add|run|rm`. Adding a task is the only step; the scheduler thread decides when each becomes due and posts its first message.

---

*Documentation generated for nl-veil — worker/sched.zig source analysis.*
